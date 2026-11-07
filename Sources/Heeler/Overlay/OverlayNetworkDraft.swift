import Foundation
import HeelerOverlay

/// Editable form state behind `OverlayNetworkFormView`, validated before it
/// becomes a catalog `OverlayNetwork`. Every kind's fields live side by
/// side so switching the kind while adding does not lose typing.
struct OverlayNetworkDraft: Equatable, Sendable {
    static let defaultHostname = "heeler"

    /// Turns what the user typed into a config server URL (a bare user name
    /// becomes the official server's). The package owns the rules; tests
    /// inject their own. Never part of the draft's equality.
    struct ConfigServerNormalizer: Equatable, Sendable {
        let normalize: @Sendable (String) -> String?

        static let package = ConfigServerNormalizer { EasyTierConfigServer.normalizedURL($0) }

        static func == (_: Self, _: Self) -> Bool { true }
    }

    /// One moon row as typed: a 10-to-16-hex-digit world ID and a
    /// 10-hex-digit seed.
    struct MoonDraft: Identifiable, Equatable, Sendable {
        let id: UUID
        var worldID: String
        var seed: String

        init(id: UUID = UUID(), worldID: String = "", seed: String = "") {
            self.id = id
            self.worldID = worldID
            self.seed = seed
        }

        init(moon: ZeroTierMoon) {
            self.init(
                worldID: OverlayNetwork.hex(moon.worldID, digits: 16),
                seed: OverlayNetwork.hex(moon.seed, digits: 10))
        }

        /// Both fields blank: an unfinished row Save leaves out.
        var isBlank: Bool {
            worldID.trimmingCharacters(in: .whitespaces).isEmpty
                && seed.trimmingCharacters(in: .whitespaces).isEmpty
        }

        var moon: ZeroTierMoon? {
            guard
                let worldID = OverlayNetwork.zeroTierMoonWorldID(worldID),
                let seed = OverlayNetwork.zeroTierMoonSeed(seed)
            else { return nil }
            return ZeroTierMoon(worldID: worldID, seed: seed)
        }
    }

    var name = ""
    var kind: OverlayKind = .tailscale
    /// Tailscale and EasyTier: this device's machine name on the network.
    var hostname = OverlayNetworkDraft.defaultHostname
    /// Tailscale: blank uses Tailscale's own coordination server.
    var controlURL = ""
    /// ZeroTier: 16 hex digits.
    var networkID = ""
    /// ZeroTier moons to orbit.
    var moons: [MoonDraft] = []
    /// ZeroTier: a custom planet (a validated World file), nil for
    /// ZeroTier's own roots.
    var planet: Data?
    /// EasyTier.
    var networkName = ""
    /// EasyTier peer URIs, one per line or comma-separated.
    var peers = ""
    /// EasyTier fixed address in CIDR form; blank asks the network's DHCP.
    var ipv4 = ""
    /// The kind's typed secret. Blank keeps the stored one when editing.
    var secret = ""
    /// EasyTier: whether the app holds the network or a config server does.
    var easyTierSource = OverlayNetwork.EasyTierSource.manual
    /// EasyTier config server: a user name or a full server URL, shown in
    /// the clear while editing (it is prefilled from the Keychain).
    var configServer = ""
    /// EasyTier config server: minted with the draft, kept on edit.
    var machineID = UUID()
    /// Config Server: refuse a server without EasyTier's encrypted tunnel.
    var requireEncryption = true
    var normalizer = ConfigServerNormalizer.package
    /// The source the edited network was saved with: its stored secret
    /// belongs to that source only.
    private(set) var savedEasyTierSource: OverlayNetwork.EasyTierSource?

    init(normalizer: ConfigServerNormalizer = .package) {
        self.normalizer = normalizer
    }

    init(network: OverlayNetwork, configServerURL: String? = nil, normalizer: ConfigServerNormalizer = .package) {
        self.normalizer = normalizer
        name = network.name
        kind = network.kind
        switch network.settings {
        case .tailscale(let hostname, let controlURL):
            self.hostname = hostname
            self.controlURL = controlURL?.absoluteString ?? ""
        case .zerotier(let networkID, let moons, let planet):
            self.networkID = networkID
            self.moons = moons.map(MoonDraft.init(moon:))
            self.planet = planet
        case .easytier(let networkName, let peers, let hostname, let ipv4):
            self.networkName = networkName
            self.peers = peers.joined(separator: "\n")
            self.hostname = hostname
            self.ipv4 = ipv4 ?? ""
            savedEasyTierSource = .manual
        case .easytierConfigServer(let server, let machineID, let hostname, let requireEncryption):
            easyTierSource = .configServer
            self.requireEncryption = requireEncryption
            savedEasyTierSource = .configServer
            configServer = configServerURL ?? server
            self.machineID = machineID
            self.hostname = hostname
        }
    }

    /// The normalized config server URL, token included; nil until valid.
    var configServerURL: String? {
        let trimmed = configServer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = normalizer.normalize(trimmed) else { return nil }
        return OverlayNetwork.easyTierConfigServerOrigin(url) == nil ? nil : url
    }

    var peerList: [String] {
        peers.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// nil for a blank field; also nil for anything but an https URL with a
    /// host, which `isValid` rejects. Plain http would expose the login and
    /// node keys exchange to the network path.
    var controlURLValue: URL? {
        let trimmed = controlURL.trimmingCharacters(in: .whitespaces)
        guard
            !trimmed.isEmpty,
            let url = URL(string: trimmed),
            url.scheme?.lowercased() == "https",
            let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }

    /// Blank (Tailscale's own server) or an https URL with a host.
    var controlURLIsValid: Bool {
        controlURL.trimmingCharacters(in: .whitespaces).isEmpty || controlURLValue != nil
    }

    /// Peers that are not `tcp://host:port` or `udp://host:port`, as typed.
    var invalidPeers: [String] {
        peerList.filter { !Self.isValidPeer($0) }
    }

    /// Moon rows that are filled in but not two valid fields.
    var invalidMoons: [MoonDraft] {
        moons.filter { !$0.isBlank && $0.moon == nil }
    }

    /// The moons Save keeps: valid rows, blank ones dropped, no repeats.
    var moonList: [ZeroTierMoon] {
        var seen = Set<ZeroTierMoon>()
        return moons.compactMap(\.moon).filter { seen.insert($0).inserted }
    }

    /// nil for a blank field; `ipv4IsValid` rejects anything else that
    /// does not parse.
    var ipv4Value: String? {
        OverlayNetwork.easyTierIPv4(ipv4)
    }

    var ipv4IsValid: Bool {
        ipv4.trimmingCharacters(in: .whitespaces).isEmpty || ipv4Value != nil
    }

    /// EasyTier widens a /32 virtual address to its /24, which the form
    /// points out rather than refuses.
    var ipv4IsHostPrefix: Bool {
        ipv4Value?.hasSuffix("/32") ?? false
    }

    static func isValidPeer(_ peer: String) -> Bool {
        guard
            let components = URLComponents(string: peer),
            let scheme = components.scheme?.lowercased(),
            scheme == "tcp" || scheme == "udp",
            let host = components.host, !host.isEmpty,
            let port = components.port, (1...65535).contains(port)
        else { return false }
        return true
    }

    var isValid: Bool {
        let hostnameIsSet = !hostname.trimmingCharacters(in: .whitespaces).isEmpty
        switch kind {
        case .tailscale:
            return hostnameIsSet && controlURLIsValid
        case .zerotier:
            return OverlayNetwork.zeroTierNetworkID(networkID) != nil && invalidMoons.isEmpty
        case .easytier where easyTierSource == .configServer:
            return hostnameIsSet && configServerURL != nil
        case .easytier:
            return hostnameIsSet
                && !networkName.trimmingCharacters(in: .whitespaces).isEmpty
                && !peerList.isEmpty
                && invalidPeers.isEmpty
                && ipv4IsValid
        }
    }

    /// Form-level validity including the secret: an EasyTier network cannot
    /// join without one, so a new network (or one without a stored secret)
    /// requires it. A Tailscale auth key is optional — without one the node
    /// asks for an interactive sign-in.
    func canSave(hasStoredSecret: Bool) -> Bool {
        guard isValid else { return false }
        guard kind == .easytier, secretUpdate == nil else { return true }
        // A stored secret of the other source is not this source's secret.
        return hasStoredSecret && (savedEasyTierSource ?? easyTierSource) == easyTierSource
    }

    func makeNetwork(id: UUID = UUID()) -> OverlayNetwork? {
        guard isValid else { return nil }
        let hostname = hostname.trimmingCharacters(in: .whitespaces)
        let settings: OverlayNetwork.Settings =
            switch kind {
            case .tailscale:
                .tailscale(hostname: hostname, controlURL: controlURLValue)
            case .zerotier:
                .zerotier(
                    networkID: networkID.trimmingCharacters(in: .whitespaces).lowercased(),
                    moons: moonList,
                    planet: planet)
            case .easytier:
                switch easyTierSource {
                case .manual:
                    .easytier(
                        networkName: networkName.trimmingCharacters(in: .whitespaces),
                        peers: peerList,
                        hostname: hostname,
                        ipv4: ipv4Value)
                case .configServer:
                    .easytierConfigServer(
                        server: configServerURL.flatMap(OverlayNetwork.easyTierConfigServerOrigin)
                            ?? "",
                        machineID: machineID,
                        hostname: hostname,
                        requireEncryption: requireEncryption)
                }
            }
        return OverlayNetwork(
            id: id, name: name.trimmingCharacters(in: .whitespaces), settings: settings)
    }

    /// What to hand the store as the secret: new text, or nil to keep.
    var secretUpdate: String? {
        guard kind.secretLabel != nil else { return nil }
        if kind == .easytier, easyTierSource == .configServer {
            return configServerURL
        }
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
