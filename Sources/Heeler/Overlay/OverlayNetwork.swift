import Foundation
import HeelerOverlay

/// A user-configured Overlay Network (CONTEXT.md): an in-process Tailscale,
/// ZeroTier, or EasyTier node a Host's first hop can be dialled through
/// (ADR 0021). Carries only non-secret settings; the auth key, network
/// secret, and ZeroTier identity live in the Keychain under
/// `OverlaySecretAccount`.
struct OverlayNetwork: Identifiable, Codable, Hashable, Sendable {
    /// Each case's settings are exactly what that overlay needs besides its
    /// secret. The kind is the case; there is no separate `kind` to disagree.
    enum Settings: Hashable, Sendable {
        /// `hostname` is this device's machine name on the tailnet; a nil
        /// `controlURL` uses Tailscale's coordination server.
        case tailscale(hostname: String, controlURL: URL?)
        /// The 16-hex-digit network id, lowercased, the moons this
        /// network's node orbits besides the planet, and a custom planet
        /// (a ZeroTier World file of a self-hosted root) or nil for
        /// ZeroTier's own. Each network has its own planet; networks with
        /// different planets run side by side (ADR 0021).
        case zerotier(networkID: String, moons: [ZeroTierMoon] = [], planet: Data? = nil)
        /// Peer URIs such as `tcp://public.easytier.top:11010`; `ipv4` is a
        /// fixed virtual address in CIDR form, nil for the network's DHCP.
        case easytier(networkName: String, peers: [String], hostname: String, ipv4: String? = nil)
        /// An EasyTier network an EasyTier config server (its web console)
        /// assigns. `server` is the server's `scheme://host:port` only: the
        /// token after it is an account credential and lives in the Keychain
        /// with the rest of the URL. `machineID` is what the console lists
        /// this device under; the app keeps it because iOS has no machine id.
        /// `requireEncryption` refuses a server that does not offer
        /// EasyTier's encrypted web tunnel instead of using it in clear text
        /// (`EasyTierConfigServer.requireEncryption`); on unless turned off.
        case easytierConfigServer(
            server: String, machineID: UUID, hostname: String, requireEncryption: Bool = true)
    }

    /// EasyTier network sources as persisted under `source`; an entry with
    /// any other value was written by a newer build and is kept untouched.
    enum EasyTierSource: String {
        case manual
        case configServer
    }

    let id: UUID
    var name: String
    var settings: Settings

    var kind: OverlayKind {
        switch settings {
        case .tailscale: .tailscale
        case .zerotier: .zerotier
        case .easytier, .easytierConfigServer: .easytier
        }
    }

    /// Blank names fall back to the kind's display name.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? kind.displayName : trimmed
    }

    /// This device's name on the network, where the overlay has one.
    var deviceName: String? {
        switch settings {
        case .tailscale(let hostname, _), .easytier(_, _, let hostname, _),
            .easytierConfigServer(_, _, let hostname, _):
            hostname
        case .zerotier:
            nil
        }
    }

    /// The Tailscale coordination server this network signs in to; nil for
    /// Tailscale's own and for other kinds.
    var tailscaleControlURL: URL? {
        guard case .tailscale(_, let controlURL) = settings else { return nil }
        return controlURL
    }

    init(id: UUID = UUID(), name: String, settings: Settings) {
        self.id = id
        self.name = name
        self.settings = settings
    }

    /// Flat keys so an older build can at least read `id`, `name`, and
    /// `kind` of an entry it cannot otherwise decode (see
    /// `OverlayNetworkStore`, which preserves such entries untouched).
    private enum CodingKeys: String, CodingKey {
        case id, name, kind
        case hostname, controlURL, networkID, networkName, peers, moons, ipv4, planet
        case source, server, machineID, requireEncryption
    }

    /// A moon as persisted: hex text, because the catalog round-trips
    /// through `JSONValue` and a 64-bit world ID does not survive a Double.
    private struct PersistedMoon: Codable {
        let worldID: String
        let seed: String

        init(_ moon: ZeroTierMoon) {
            worldID = OverlayNetwork.hex(moon.worldID, digits: 16)
            seed = OverlayNetwork.hex(moon.seed, digits: 10)
        }

        var moon: ZeroTierMoon? {
            guard
                let worldID = OverlayNetwork.zeroTierMoonWorldID(worldID),
                let seed = OverlayNetwork.zeroTierMoonSeed(seed)
            else { return nil }
            return ZeroTierMoon(worldID: worldID, seed: seed)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let kindValue = try container.decode(String.self, forKey: .kind)
        switch OverlayKind(rawValue: kindValue) {
        case .tailscale:
            settings = .tailscale(
                hostname: try container.decode(String.self, forKey: .hostname),
                controlURL: try container.decodeIfPresent(URL.self, forKey: .controlURL))
        case .zerotier:
            // Networks saved before moons existed have none.
            let moons = try container.decodeIfPresent([PersistedMoon].self, forKey: .moons) ?? []
            settings = .zerotier(
                networkID: try container.decode(String.self, forKey: .networkID),
                // A malformed moon is dropped rather than making the whole
                // catalog unreadable; the node could not orbit it anyway.
                moons: moons.compactMap(\.moon),
                // Base64; networks saved before per-network planets have none.
                planet: try container.decodeIfPresent(Data.self, forKey: .planet))
        case .easytier:
            // Networks saved before config servers existed are manual.
            let sourceValue = try container.decodeIfPresent(String.self, forKey: .source)
            switch sourceValue.map(EasyTierSource.init(rawValue:)) ?? .manual {
            case .manual:
                break
            case .configServer:
                settings = .easytierConfigServer(
                    server: try container.decode(String.self, forKey: .server),
                    machineID: try container.decode(UUID.self, forKey: .machineID),
                    hostname: try container.decode(String.self, forKey: .hostname),
                    // Networks saved before the setting existed require it.
                    requireEncryption: try container.decodeIfPresent(Bool.self, forKey: .requireEncryption)
                        ?? true)
                return
            case nil:
                throw DecodingError.dataCorruptedError(
                    forKey: .source, in: container,
                    debugDescription: "Unknown EasyTier source: \(sourceValue ?? "")")
            }
            settings = .easytier(
                networkName: try container.decode(String.self, forKey: .networkName),
                peers: try container.decodeIfPresent([String].self, forKey: .peers) ?? [],
                hostname: try container.decode(String.self, forKey: .hostname),
                ipv4: try container.decodeIfPresent(String.self, forKey: .ipv4))
        case nil:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "Unknown overlay kind: \(kindValue)")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind.rawValue, forKey: .kind)
        switch settings {
        case .tailscale(let hostname, let controlURL):
            try container.encode(hostname, forKey: .hostname)
            try container.encodeIfPresent(controlURL, forKey: .controlURL)
        case .zerotier(let networkID, let moons, let planet):
            try container.encode(networkID, forKey: .networkID)
            if !moons.isEmpty {
                try container.encode(moons.map(PersistedMoon.init), forKey: .moons)
            }
            try container.encodeIfPresent(planet, forKey: .planet)
        case .easytier(let networkName, let peers, let hostname, let ipv4):
            try container.encode(networkName, forKey: .networkName)
            try container.encode(peers, forKey: .peers)
            try container.encode(hostname, forKey: .hostname)
            try container.encodeIfPresent(ipv4, forKey: .ipv4)
        case .easytierConfigServer(let server, let machineID, let hostname, let requireEncryption):
            try container.encode(EasyTierSource.configServer.rawValue, forKey: .source)
            try container.encode(server, forKey: .server)
            try container.encode(machineID, forKey: .machineID)
            try container.encode(hostname, forKey: .hostname)
            try container.encode(requireEncryption, forKey: .requireEncryption)
        }
    }

    /// Whether a sign-in link the node reported may be offered to the user.
    /// Only https, except plain http to the network's own http coordination
    /// server (a local Headscale saved before https was required).
    func acceptsLoginURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host(), !host.isEmpty else {
            return false
        }
        if scheme == "https" { return true }
        guard
            scheme == "http",
            case .tailscale(_, let controlURL?) = settings,
            controlURL.scheme?.lowercased() == "http"
        else { return false }
        return controlURL.host()?.lowercased() == host.lowercased()
    }

    /// A ZeroTier network id as the node API takes it: exactly 16 hex
    /// digits, nothing else.
    static func zeroTierNetworkID(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 16, trimmed.allSatisfy(\.isHexDigit) else { return nil }
        return UInt64(trimmed, radix: 16)
    }

    /// A moon's world ID as `zerotier-cli orbit` takes it: 10 to 16 hex
    /// digits (usually its root's address zero-padded to 16), never zero.
    static func zeroTierMoonWorldID(_ text: String) -> UInt64? {
        hexValue(text, digits: 10...16)
    }

    /// A moon's seed: the 10-hex-digit (40-bit) address of one of its
    /// roots, never zero.
    static func zeroTierMoonSeed(_ text: String) -> UInt64? {
        hexValue(text, digits: 10...10)
    }

    private static func hexValue(_ text: String, digits: ClosedRange<Int>) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard
            digits.contains(trimmed.count),
            trimmed.allSatisfy(\.isHexDigit),
            let value = UInt64(trimmed, radix: 16),
            value != 0
        else { return nil }
        return value
    }

    /// An EasyTier fixed address normalized to `a.b.c.d/prefix`, or nil
    /// unless it is what the package accepts: dotted decimal without leading
    /// zeros, a 1…32 prefix, and not unspecified (0.x), loopback (127.x), or
    /// multicast/reserved (224 and up).
    static func easyTierIPv4(_ text: String) -> String? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(
            separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = decimal(parts[1], maximum: 32), prefix >= 1 else {
            return nil
        }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var values: [Int] = []
        for octet in octets {
            guard let value = decimal(octet, maximum: 255) else { return nil }
            values.append(value)
        }
        guard values[0] != 0, values[0] != 127, values[0] < 224 else { return nil }
        return values.map(String.init).joined(separator: ".") + "/\(prefix)"
    }

    /// One to three ASCII digits, no leading zero, at most `maximum`.
    private static func decimal(_ text: Substring, maximum: Int) -> Int? {
        guard
            (1...3).contains(text.count),
            text.allSatisfy(\.isASCIIDigit),
            text == "0" || !text.hasPrefix("0"),
            let value = Int(text), value <= maximum
        else { return nil }
        return value
    }

    /// `scheme://host:port` of a normalized config server URL — what may be
    /// shown and saved outside the Keychain — or nil when it has no host.
    static func easyTierConfigServerOrigin(_ url: String) -> String? {
        guard
            let components = URLComponents(string: url),
            let scheme = components.scheme, let host = components.host, !host.isEmpty
        else { return nil }
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    /// The token (the path after the origin) of a config server URL, shown
    /// with all but its first two characters masked.
    static func maskedConfigServerToken(_ url: String) -> String? {
        guard let path = URLComponents(string: url)?.path else { return nil }
        let token = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard !token.isEmpty else { return nil }
        return String(token.prefix(2)) + String(repeating: "•", count: max(3, token.count - 2))
    }

    static func hex(_ value: UInt64, digits: Int) -> String {
        let text = String(value, radix: 16)
        return String(repeating: "0", count: max(0, digits - text.count)) + text
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}

extension OverlayKind {
    var displayName: String {
        switch self {
        case .tailscale: "Tailscale"
        case .zerotier: "ZeroTier"
        case .easytier: "EasyTier"
        }
    }

    /// What the per-network Keychain secret is called in the form, or nil
    /// when the user never types one (ZeroTier mints its own identity).
    var secretLabel: String? {
        switch self {
        case .tailscale: "Auth key"
        case .zerotier: nil
        case .easytier: "Network secret"
        }
    }
}

/// Keychain accounts for Overlay Network secrets, under their own service so
/// they never mix with Host passwords (`dev.bybee.heeler.ssh`).
enum OverlaySecretAccount {
    static let service = "dev.bybee.heeler.overlay"

    /// The typed secret for a network: a Tailscale auth key or an EasyTier
    /// network secret. ZeroTier networks have none.
    /// A config-server network's secret is the server URL itself: its
    /// token is the account it registers to, as good as a password.
    static func secret(for network: OverlayNetwork) -> String? {
        switch network.settings {
        case .tailscale: "overlay-tailscale-authkey-\(network.id.uuidString)"
        case .easytier: "overlay-easytier-secret-\(network.id.uuidString)"
        case .easytierConfigServer: "overlay-easytier-configserver-\(network.id.uuidString)"
        case .zerotier: nil
        }
    }

    /// libzt runs one node per process, so the device has one ZeroTier
    /// identity shared by every ZeroTier network.
    static let zeroTierIdentity = "overlay-zerotier-identity"
}
