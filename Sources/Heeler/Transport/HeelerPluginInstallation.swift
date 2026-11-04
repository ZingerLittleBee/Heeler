import Foundation

/// herdr's plugin listing, from the `plugin.list` RPC or the
/// `herdr plugin list --json` CLI: a lenient subset of `InstalledPluginInfo`
/// (herdr schema), since the rest of the manifest is irrelevant here and
/// partly outside the wire generator's reach.
struct PluginListResult: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        struct Source: Decodable, Sendable {
            let kind: String?
            /// A GitHub install's repository.
            let owner: String?
            let repo: String?
        }

        let pluginID: String?
        var pluginRoot: String? = nil
        let version: String?
        let enabled: Bool?
        let source: Source?
        let warnings: [String]?

        var isEnabled: Bool { enabled != false }

        private enum CodingKeys: String, CodingKey {
            case pluginID = "plugin_id"
            case pluginRoot = "plugin_root"
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

/// `plugin.enable`'s `plugin_enabled` result. Heeler rereads the plugin
/// list afterwards, so the entry itself is not needed.
struct PluginEnabledResult: Decodable, Sendable {}

/// herdr failed or refused one `HeelerPluginStep` it ran through its CLI.
struct HeelerPluginStepError: Error, Equatable, Sendable {
    let step: HeelerPluginStep
    let exitStatus: Int32
    /// What herdr printed, stderr first: the CLI reports failures there.
    let output: String

    init(step: HeelerPluginStep, exitStatus: Int32, stderr: Data, stdout: Data) {
        self.step = step
        self.exitStatus = exitStatus
        let errors = String(decoding: stderr, as: UTF8.self)
        output =
            errors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(decoding: stdout, as: UTF8.self) : errors
    }

    /// The build step (`npm ci`) failed, typically because SSH commands do
    /// not find Node.js on the Host.
    var isBuildFailure: Bool { output.contains("plugin build failed") }
    /// git could not fetch the plugin branch.
    var isDownloadFailure: Bool { output.contains("git failed") }
    /// The CLI is newer than the session's running server, which herdr asks
    /// to restart first (`protocol_guard.rs`).
    var needsServerRestart: Bool { output.contains("restart the Herdr server") }
    /// The install stopped before herdr ran because the Host has no usable
    /// Node.js (``NodeToolchainProbe``).
    var nodeProblem: NodeToolchainProblem? {
        NodeToolchainProblem(exitStatus: exitStatus, output: output)
    }

    /// herdr's own words without the install preview it prints first, or
    /// what the Host's shell setup printed before them (a tool's warnings,
    /// say): from herdr's first `error` line when there is one, then the
    /// last `lineLimit` non-empty lines, at most `characterLimit` long.
    func detail(lineLimit: Int = 10, characterLimit: Int = 800) -> String? {
        var lines: [Substring] = []
        var isInPreview = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("Plugin ") && line.hasSuffix("preview:") {
                isInPreview = true
                continue
            }
            if isInPreview, line.first?.isWhitespace == true { continue }
            isInPreview = false
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line) }
        }
        if let firstError = lines.firstIndex(where: { $0.hasPrefix("error") }) {
            lines.removeSubrange(..<firstError)
        }
        let text = lines.suffix(lineLimit).joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        return text.count > characterLimit ? "…" + text.suffix(characterLimit - 1) : text
    }
}

/// The Host could not fetch the plugin branch's manifest, or it named no
/// `X.Y.Z` version.
struct PluginBranchVersionError: Error, Equatable, Sendable {
    let exitStatus: Int32
    /// What git printed, when it said why.
    let output: String
}

/// The Heeler plugin as herdr reports it on one Host.
struct HeelerPluginInstallation: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// `herdr plugin install` from GitHub; reinstalling updates it.
        case github
        /// `herdr plugin link` to a checkout; install refuses to replace it.
        case local
        case unknown

        init(_ source: PluginListResult.Entry.Source?) {
            switch source?.kind {
            case "github": self = .github
            case "local": self = .local
            default: self = .unknown
            }
        }
    }

    let pluginID: String
    let pluginRoot: String?
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
    /// Beside this enabled legacy-id plugin, herdr also lists the current
    /// id, disabled: that plugin's source. Once the legacy id is removed,
    /// it is the plugin to turn on, and a linked one cannot be reinstalled.
    let disabledCurrentIDSource: Source?
    /// `owner/repo` of a GitHub install, when herdr reports it.
    let repository: String?

    /// Installed under a name the plugin used before 0.4.0.
    var isLegacyID: Bool { pluginID != SSHTransportSettings.notificationPluginID }

    var parsedVersion: PluginVersion? { PluginVersion(version) }

    /// A GitHub install of this repository, the only plugin an install may
    /// replace: herdr refuses a linked checkout and may refuse an unknown
    /// source, a fork's install would quietly move to this repository, and
    /// a GitHub install that does not name its repository may be a fork.
    var isOwnGitHubInstall: Bool {
        source == .github
            && repository.map {
                $0.caseInsensitiveCompare(HostSetupGuide.pluginRepository) == .orderedSame
            } ?? false
    }

    /// Whether an install may replace this plugin: one of this repository's
    /// GitHub installs, with a version herdr read from the manifest itself.
    /// After a manifest warning, herdr reports its registry's version, which
    /// may be stale, so the app could not rule out a downgrade.
    var isReplaceableByInstall: Bool {
        isOwnGitHubInstall && !hasManifestWarning && parsedVersion != nil
    }

    /// Picks the entry with `PluginListResult.heelerEntry(enabledOnly: false)`,
    /// the same rule Notification Registration uses, plus disabled fallback.
    init?(_ result: PluginListResult) {
        guard let entry = result.heelerEntry(enabledOnly: false),
            let pluginID = entry.pluginID
        else { return nil }
        let currentID = SSHTransportSettings.notificationPluginID
        let leftovers =
            pluginID == currentID
            ? result.heelerEntries.filter { $0.pluginID != pluginID && $0.isEnabled }
                .compactMap(\.pluginID)
            : []
        let disabledCurrentEntry =
            pluginID == currentID
            ? nil : result.heelerEntries.first { $0.pluginID == currentID && !$0.isEnabled }
        self.init(
            pluginID: pluginID,
            pluginRoot: entry.pluginRoot,
            version: entry.version ?? "",
            isEnabled: entry.isEnabled,
            source: Source(entry.source),
            hasManifestWarning: entry.warnings?.contains {
                $0.hasPrefix("manifest unavailable")
            } == true,
            leftoverLegacyIDs: leftovers,
            disabledCurrentIDSource: disabledCurrentEntry.map { Source($0.source) },
            repository: entry.source.flatMap { source in
                guard let owner = source.owner, let repo = source.repo else { return nil }
                return "\(owner)/\(repo)"
            })
    }

    init(
        pluginID: String = SSHTransportSettings.notificationPluginID,
        pluginRoot: String? = nil,
        version: String,
        isEnabled: Bool = true,
        source: Source = .github,
        hasManifestWarning: Bool = false,
        leftoverLegacyIDs: [String] = [],
        disabledCurrentIDSource: Source? = nil,
        repository: String? = HostSetupGuide.pluginRepository
    ) {
        self.pluginID = pluginID
        self.pluginRoot = pluginRoot
        self.version = version
        self.isEnabled = isEnabled
        self.source = source
        self.hasManifestWarning = hasManifestWarning
        self.leftoverLegacyIDs = leftoverLegacyIDs
        self.disabledCurrentIDSource = disabledCurrentIDSource
        self.repository = repository
    }
}
