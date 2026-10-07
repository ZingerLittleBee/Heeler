import Foundation

/// herdr's plugin listing, from the `plugin.list` RPC or the
/// `herdr plugin list --json` CLI: a lenient subset of `InstalledPluginInfo`
/// (herdr schema), since the rest of the manifest is irrelevant here and
/// partly outside the wire generator's reach.
struct PluginListResult: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        struct Source: Decodable, Sendable {
            let kind: String?
        }

        let pluginID: String?
        let version: String?
        let enabled: Bool?
        let source: Source?
        let warnings: [String]?

        var isEnabled: Bool { enabled != false }

        private enum CodingKeys: String, CodingKey {
            case pluginID = "plugin_id"
            case version
            case enabled
            case source
            case warnings
        }
    }

    /// The Heeler plugin's current id, then its legacy ids, newest first.
    static let knownIDs =
        [SSHTransportSettings.notificationPluginID] + SSHTransportSettings.legacyNotificationPluginIDs

    let plugins: [Entry]

    /// Every Heeler plugin entry, in `knownIDs` order.
    var heelerEntries: [Entry] {
        Self.knownIDs.compactMap { id in plugins.first { $0.pluginID == id } }
    }

    /// The entry herdr runs hooks for, and so the one Notification
    /// Registration writes to: the first known id that is enabled. Unless
    /// `enabledOnly`, a disabled entry stands in when none is enabled, so a
    /// switched-off plugin reads as disabled rather than absent.
    func heelerEntry(enabledOnly: Bool) -> Entry? {
        let entries = heelerEntries
        return entries.first(where: \.isEnabled) ?? (enabledOnly ? nil : entries.first)
    }
}

/// The Heeler plugin as herdr reports it on one Host.
struct HeelerPluginInstallation: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// `herdr plugin install` from GitHub; reinstalling updates it.
        case github
        /// `herdr plugin link` to a checkout; install refuses to replace it.
        case local
        case unknown
    }

    let pluginID: String
    /// The manifest's version string as herdr reported it.
    let version: String
    let isEnabled: Bool
    let source: Source
    /// herdr could not reread the manifest and kept its last registry
    /// entry, so `version` may be stale.
    let hasManifestWarning: Bool
    /// Legacy ids still installed and enabled beside this current-id
    /// plugin: both run their hooks, so a Host can notify twice.
    let leftoverLegacyIDs: [String]

    /// Installed under a name the plugin used before 0.4.0.
    var isLegacyID: Bool { pluginID != SSHTransportSettings.notificationPluginID }

    var parsedVersion: PluginVersion? { PluginVersion(version) }

    /// Picks the entry with `PluginListResult.heelerEntry(enabledOnly: false)`,
    /// the same rule Notification Registration uses, plus disabled fallback.
    init?(_ result: PluginListResult) {
        guard let entry = result.heelerEntry(enabledOnly: false),
            let pluginID = entry.pluginID
        else { return nil }
        let source: Source =
            switch entry.source?.kind {
            case "github": .github
            case "local": .local
            default: .unknown
            }
        let leftovers =
            pluginID == SSHTransportSettings.notificationPluginID
            ? result.heelerEntries.filter { $0.pluginID != pluginID && $0.isEnabled }
                .compactMap(\.pluginID)
            : []
        self.init(
            pluginID: pluginID,
            version: entry.version ?? "",
            isEnabled: entry.isEnabled,
            source: source,
            hasManifestWarning: entry.warnings?.contains {
                $0.hasPrefix("manifest unavailable")
            } == true,
            leftoverLegacyIDs: leftovers)
    }

    init(
        pluginID: String = SSHTransportSettings.notificationPluginID,
        version: String,
        isEnabled: Bool = true,
        source: Source = .github,
        hasManifestWarning: Bool = false,
        leftoverLegacyIDs: [String] = []
    ) {
        self.pluginID = pluginID
        self.version = version
        self.isEnabled = isEnabled
        self.source = source
        self.hasManifestWarning = hasManifestWarning
        self.leftoverLegacyIDs = leftoverLegacyIDs
    }
}
