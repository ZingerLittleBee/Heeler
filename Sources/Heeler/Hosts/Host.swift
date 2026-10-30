import Foundation

/// One way to reach a Host (ADR 0022): the address to dial, and optionally a
/// Jump Host in front of it and an Overlay Network carrying the first hop. A
/// Host lists one or more; the Console races them and keeps whichever reaches
/// the Host first, so a Host can be dialled on its LAN address at home and
/// through an Overlay Network or Jump Host elsewhere without any rule saying
/// which applies where.
struct HostRoute: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var address: String
    var port: Int
    /// Optional Jump Host this route goes through. Blank means the device
    /// dials `address`/`port` itself; when set, they are resolved from the
    /// Jump Host and normally point at a loopback port held open by a
    /// reverse tunnel.
    var jumpAddress: String
    var jumpPort: Int
    /// Account on the Jump Host. Blank reuses the Host's `username`, which is
    /// the common case only when both machines share an account name.
    var jumpUsername: String
    /// Optional Overlay Network carrying the first hop — the Host, or the
    /// Jump Host when one is set (ADR 0021). nil dials over the device's own
    /// network. With an overlay, the first hop's address is its overlay IP or
    /// name (MagicDNS, for Tailscale).
    var overlayNetworkID: UUID?

    init(
        id: UUID = UUID(),
        address: String,
        port: Int = 22,
        jumpAddress: String = "",
        jumpPort: Int = 22,
        jumpUsername: String = "",
        overlayNetworkID: UUID? = nil
    ) {
        self.id = id
        self.address = address
        self.port = port
        self.jumpAddress = jumpAddress
        self.jumpPort = jumpPort
        self.jumpUsername = jumpUsername
        self.overlayNetworkID = overlayNetworkID
    }

    /// Whether this route goes through a Jump Host.
    var usesJumpHost: Bool {
        !jumpAddress.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The address the device itself dials: the Jump Host's when there is
    /// one, otherwise the Host's. An Overlay Network carries this hop.
    var firstHopAddress: String {
        usesJumpHost ? jumpAddress : address
    }

    /// `address`, with the port when it is not 22.
    var endpointDescription: String {
        port == 22 ? address : "\(address):\(port)"
    }

    /// One line naming how this route reaches the Host:
    /// `100.64.0.5 · home`, `127.0.0.1:2222 via vps.example`.
    func summary(networkName: (UUID) -> String) -> String {
        var summary = endpointDescription
        if usesJumpHost {
            let jump = jumpAddress.trimmingCharacters(in: .whitespaces)
            summary += " via \(jumpPort == 22 ? jump : "\(jump):\(jumpPort)")"
        }
        if let overlayNetworkID {
            summary += " · \(networkName(overlayNetworkID))"
        }
        return summary
    }
}

/// The server a Host reaches. Desktop herdr-core is a separate backend,
/// not another socket spelling of the legacy herdr protocol.
enum HostBackend: String, Codable, CaseIterable, Hashable, Sendable {
    case herdr
    case herdrCore

    var displayName: String {
        switch self {
        case .herdr: "herdr"
        case .herdrCore: "herdr-app / herdr-core"
        }
    }
}

/// A user-added Host (CONTEXT.md): who the machine is, how to authenticate,
/// which herdr session to reach, and the Routes it can be reached on. Never
/// carries a secret — the password lives in the Keychain keyed by `id`, and
/// private keys live in `DeviceKeyStore` or `RSAKeyStore`.
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
    var username: String
    var authMethod: AuthMethod
    var backend: HostBackend
    /// Persisted session selection; onboarding discovers available sessions,
    /// while this field remains editable for older herdr versions. Blank
    /// means the default herdr session.
    var sessionName: String
    /// The Host's own herdr endpoint, from a Pairing Code v2 (ADR 0023). When
    /// set it wins over `sessionName`: every connection uses its socket and
    /// every herdr exec its launcher. nil keeps the home-relative session
    /// socket and the `herdr` on the SSH PATH.
    var herdrEndpoint: HerdrEndpoint?
    /// The ways to reach this Host, in the user's order: never empty. The
    /// first is the primary route, which names the Host where one address
    /// is shown and is what builds without Routes connect to.
    var routes: [HostRoute]

    /// `socatPath` is deliberately absent: Hosts serialized before ADR 0011
    /// still carry it on disk, and leaving it out of the keys both ignores it
    /// on decode and drops it on the Host's next save.
    private enum CodingKeys: String, CodingKey {
        case herdrEndpoint
        case id, name, username, authMethod, backend, sessionName
        case routes
        // The primary route, flattened as Hosts were saved before Routes
        // (ADR 0022), so a build without them still decodes and connects it.
        case address, port, jumpAddress, jumpPort, jumpUsername
        case overlayNetworkID
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        username: String,
        authMethod: AuthMethod = .deviceKey,
        backend: HostBackend = .herdr,
        sessionName: String = "",
        herdrEndpoint: HerdrEndpoint? = nil,
        routes: [HostRoute]
    ) {
        precondition(!routes.isEmpty, "A Host needs at least one route")
        self.id = id
        self.name = name
        self.username = username
        self.authMethod = authMethod
        self.backend = herdrEndpoint == nil ? backend : .herdr
        self.sessionName = sessionName
        self.herdrEndpoint = herdrEndpoint
        self.routes = routes
    }

    /// A Host with a single route, as every Host was before Routes.
    init(
        id: UUID = UUID(),
        name: String = "",
        address: String,
        port: Int = 22,
        username: String,
        authMethod: AuthMethod = .deviceKey,
        backend: HostBackend = .herdr,
        sessionName: String = "",
        jumpAddress: String = "",
        jumpPort: Int = 22,
        jumpUsername: String = "",
        herdrEndpoint: HerdrEndpoint? = nil,
        overlayNetworkID: UUID? = nil
    ) {
        self.init(
            id: id,
            name: name,
            username: username,
            authMethod: authMethod,
            backend: backend,
            sessionName: sessionName,
            herdrEndpoint: herdrEndpoint,
            routes: [
                HostRoute(
                    id: id,
                    address: address,
                    port: port,
                    jumpAddress: jumpAddress,
                    jumpPort: jumpPort,
                    jumpUsername: jumpUsername,
                    overlayNetworkID: overlayNetworkID)
            ])
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        username = try container.decode(String.self, forKey: .username)
        let authMethodValue = try container.decode(String.self, forKey: .authMethod)
        guard let decodedAuthMethod = AuthMethod(rawValue: authMethodValue) else {
            throw DecodingError.dataCorruptedError(
                forKey: .authMethod,
                in: container,
                debugDescription: "Unknown authentication method: \(authMethodValue)")
        }
        authMethod = decodedAuthMethod
        backend = try container.decodeIfPresent(HostBackend.self, forKey: .backend) ?? .herdr
        sessionName = try container.decodeIfPresent(String.self, forKey: .sessionName) ?? ""
        // Absent in Hosts saved before Pairing Code v2, and in every Host not
        // paired from one. The encoder omits nil for those Hosts.
        herdrEndpoint = try container.decodeIfPresent(HerdrEndpoint.self, forKey: .herdrEndpoint)
        guard herdrEndpoint == nil || backend == .herdr else {
            throw DecodingError.dataCorruptedError(
                forKey: .backend, in: container,
                debugDescription: "A paired herdr endpoint requires the herdr backend")
        }
        if let routes = try container.decodeIfPresent([HostRoute].self, forKey: .routes),
           !routes.isEmpty
        {
            self.routes = routes
        } else {
            // Saved before Routes, or since by a build without them (which
            // drops `routes`): the flat fields are the Host's one route. It
            // takes the Host's id, so decoding it again names the same route.
            routes = [
                HostRoute(
                    id: id,
                    address: try container.decode(String.self, forKey: .address),
                    port: try container.decode(Int.self, forKey: .port),
                    // Absent in Hosts saved before jump-host support; a blank
                    // address decodes as the direct connection they had.
                    jumpAddress: try container.decodeIfPresent(String.self, forKey: .jumpAddress)
                        ?? "",
                    jumpPort: try container.decodeIfPresent(Int.self, forKey: .jumpPort) ?? 22,
                    jumpUsername: try container.decodeIfPresent(
                        String.self, forKey: .jumpUsername) ?? "",
                    // Absent in Hosts saved before Overlay Networks.
                    overlayNetworkID: try container.decodeIfPresent(
                        UUID.self, forKey: .overlayNetworkID))
            ]
        }

        let trimmedSessionName = sessionName.trimmingCharacters(in: .whitespaces)
        guard trimmedSessionName.isEmpty || HerdrSessionName.isValid(trimmedSessionName) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sessionName, in: container, debugDescription: "Invalid herdr session name")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(username, forKey: .username)
        try container.encode(authMethod, forKey: .authMethod)
        try container.encode(backend, forKey: .backend)
        try container.encode(sessionName, forKey: .sessionName)
        try container.encodeIfPresent(herdrEndpoint, forKey: .herdrEndpoint)
        try container.encode(routes, forKey: .routes)
        let primary = primaryRoute
        try container.encode(primary.address, forKey: .address)
        try container.encode(primary.port, forKey: .port)
        try container.encode(primary.jumpAddress, forKey: .jumpAddress)
        try container.encode(primary.jumpPort, forKey: .jumpPort)
        try container.encode(primary.jumpUsername, forKey: .jumpUsername)
        try container.encodeIfPresent(primary.overlayNetworkID, forKey: .overlayNetworkID)
    }

    /// The first route: the one that names the Host where a single address
    /// is shown.
    var primaryRoute: HostRoute {
        // `routes` is never empty; the fallback only satisfies the compiler.
        routes.first ?? HostRoute(id: id, address: "")
    }

    /// The primary route's address.
    var address: String { primaryRoute.address }

    /// The primary route's port.
    var port: Int { primaryRoute.port }

    /// The Jump Host account on `route`, falling back to the Host's own
    /// username.
    func jumpUsername(on route: HostRoute) -> String {
        let trimmed = route.jumpUsername.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? username : trimmed
    }

    /// Whether `address` names this Host on any of its routes, ignoring
    /// case and surrounding spaces.
    func answers(toAddress address: String) -> Bool {
        let wanted = address.trimmingCharacters(in: .whitespaces)
        return routes.contains {
            $0.address.trimmingCharacters(in: .whitespaces)
                .caseInsensitiveCompare(wanted) == .orderedSame
        }
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "\(username)@\(address)" : trimmed
    }

    /// One line for how the Host is reached: `user@address`, with the port
    /// when it is not 22. With several routes the Console does not yet know
    /// which one a connection took, so naming the primary route's address
    /// could show one that did not answer; the line names the routes instead.
    var connectionSummary: String {
        guard routes.count == 1 else {
            return "\(username) · \(routes.count) routes"
        }
        return port == 22 ? "\(username)@\(address)" : "\(username)@\(address):\(port)"
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
/// by a Pairing Code v2 (`plugin/README.md`, ADR 0023). Both paths are
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
