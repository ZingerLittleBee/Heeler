import Foundation

/// An amux-managed Core route, not a TUI endpoint or an independently installed
/// Node Helper. The v3 wire contract is shared with amux, not a shared SDK.
struct AmuxCoreEndpoint: Codable, Hashable, Sendable {
    struct Core: Codable, Hashable, Sendable { let id: String; let generation: Int }
    struct Organization: Codable, Hashable, Sendable {
        let name: String
        let schema: Int
        let access: String
    }
    struct Helper: Codable, Hashable, Sendable {
        let kind: String
        let contract: Int
        let directory: String
        let executable: String
        let capabilities: [String]
    }

    static let requiredCapabilities: Set<String> = [
        "core-events-v1", "seen-v1", "notify-v1", "activity-v1", "enroll-v1",
    ]
    let kind: String
    let session: String
    let socketPath: String
    let executablePath: String
    let core: Core
    let organization: Organization
    let helper: Helper

    private enum CodingKeys: String, CodingKey {
        case kind, session, core, organization, helper
        case socketPath = "sock", executablePath = "herdr"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        session = try c.decode(String.self, forKey: .session)
        socketPath = try c.decode(String.self, forKey: .socketPath)
        executablePath = try c.decode(String.self, forKey: .executablePath)
        core = try c.decode(Core.self, forKey: .core)
        organization = try c.decode(Organization.self, forKey: .organization)
        helper = try c.decode(Helper.self, forKey: .helper)
        guard kind == "core", !core.id.isEmpty, core.generation == 1,
            Self.isValidSession(session), Self.isSafePath(socketPath), socketPath.hasSuffix(".sock"),
            socketPath.utf8.count <= 87, Self.isSafePath(executablePath),
            organization == Organization(name: "amux-organization", schema: 1, access: "read-only"),
            helper.kind == "amux-native", helper.contract == 1,
            Self.isSafePath(helper.directory), Self.isSafePath(helper.executable),
            Self.requiredCapabilities.isSubset(of: Set(helper.capabilities))
        else {
            throw DecodingError.dataCorruptedError(forKey: .core, in: c, debugDescription: "Unsupported amux Core pairing contract")
        }
    }

    static func isSafePath(_ value: String) -> Bool {
        value.hasPrefix("/") && value != "/" && !value.unicodeScalars.contains {
            $0.value < 32 || $0.value == 127 || $0 == "'" || $0 == "\"" || $0 == "\\"
        }
    }

    private static func isValidSession(_ value: String) -> Bool {
        (1...64).contains(value.utf8.count) && value != "." && value != ".."
            && value.lowercased() != "default" && value.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                    || $0 == 46 || $0 == 95 || $0 == 45
            }
    }

    /// A read-only probe of precisely the supplied launcher and socket. It
    /// never discovers another installation or asks a Core to start.
    func locatorScript(nonce: String) -> Data {
        let quote = HerdrCoreLocator.quoted
        return Data("""
        printf '\\n%s begin\\n' \(quote(nonce))
        printf 'kernel %s\\n' "$(uname -s)"
        if [ -x \(quote(executablePath)) ]; then
          __amux_version=$(\(quote(executablePath)) --version </dev/null) || exit 1
          printf 'executable %s\\n' \(quote(executablePath))
          printf 'version %s\\n' "$__amux_version"
        fi
        printf 'default %s\\n' \(quote(socketPath))
        if [ -S \(quote(socketPath)) ]; then printf 'socket-file 1\\n'; else printf 'socket-file 0\\n'; fi
        [ -z "$SHELL" ] || printf 'shell %s\\n' "$SHELL"
        printf '%s end\\n' \(quote(nonce))
        """.utf8)
    }
}
