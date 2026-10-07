import Foundation

/// A Heeler plugin release number, `major.minor.patch`.
struct PluginVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses a manifest `version` such as `0.6.0`. A missing patch reads as
    /// 0; a pre-release or build suffix (`-beta.1`, `+abc`) is ignored, so a
    /// pre-release compares equal to its release. Anything else is nil.
    init?(_ string: String) {
        let core = string.prefix { $0 != "-" && $0 != "+" }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let value = Int(part), value >= 0
            else { return nil }
            numbers.append(value)
        }
        self.init(numbers[0], numbers[1], numbers.count == 3 ? numbers[2] : 0)
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// The plugin version this app build ships alongside, and the app features
/// that need a newer plugin than earlier releases had.
enum HeelerPluginCompatibility {
    /// `plugin/herdr-plugin.toml`'s version when this app was built. The
    /// shared `plugin/test-vectors/plugin-version-v1.json` pins both sides,
    /// so a plugin release must update this constant too. A Host with a newer
    /// plugin (main moved ahead of this build) counts as current.
    static let bundled = PluginVersion(0, 6, 0)
}

/// An app feature that only works with a recent enough Heeler plugin.
/// The sidebar and session thresholds are exact. 0.3.0 gained the Live
/// Activity hook and 0.4.0 its row layout without a version change, so
/// those two notes only say the feature may be missing.
enum HeelerPluginFeature: CaseIterable, Hashable, Sendable {
    /// `sidebar.json`: Sync from plugin and herdr's sidebar fields.
    case sidebarFields
    /// The activity hook pushes Live Activity updates while Heeler is
    /// suspended.
    case liveActivityUpdates
    /// Pushed Live Activity updates carry the Host's Agent List Fields.
    case liveActivityRows
    /// Registrations scoped to a herdr session (ADR 0020).
    case sessionScopedNotifications

    var minimumVersion: PluginVersion {
        switch self {
        case .sidebarFields, .liveActivityUpdates: PluginVersion(0, 4, 0)
        case .liveActivityRows: PluginVersion(0, 5, 0)
        case .sessionScopedNotifications: PluginVersion(0, 6, 0)
        }
    }

    func isSupported(by version: PluginVersion) -> Bool {
        version >= minimumVersion
    }

    /// What the user loses with `installed`, and which version restores it.
    func requirementNote(installed: PluginVersion) -> String {
        switch self {
        case .sidebarFields:
            "Sync from plugin and herdr's sidebar fields need plugin \(minimumVersion) "
                + "or newer; this Host has \(installed)."
        case .liveActivityUpdates:
            "Live Activity updates while Heeler is in the background may need plugin "
                + "\(minimumVersion) or newer; this Host has \(installed)."
        case .liveActivityRows:
            "Background Live Activity updates may not follow your Agent List Fields "
                + "before plugin \(minimumVersion); this Host has \(installed)."
        case .sessionScopedNotifications:
            "Notifications from your other herdr sessions on this Host may reach this "
                + "device until the plugin is \(minimumVersion) or newer; this Host has \(installed)."
        }
    }

    /// The notes for the `features` that `installed` lacks. A plugin without
    /// background Live Activity updates has no row layout for them either,
    /// so that second note is left out.
    static func requirements(
        _ features: [HeelerPluginFeature] = allCases, installed: PluginVersion
    ) -> [HeelerPluginRequirement] {
        let missing = features.filter { !$0.isSupported(by: installed) }
        return missing
            .filter { $0 != .liveActivityRows || !missing.contains(.liveActivityUpdates) }
            .map { HeelerPluginRequirement(feature: $0, note: $0.requirementNote(installed: installed)) }
    }
}

/// A feature a Host's plugin is too old for, with the sentence that says so.
struct HeelerPluginRequirement: Hashable, Sendable {
    let feature: HeelerPluginFeature
    let note: String
}

/// What one Host's plugin read established.
enum HeelerPluginStatus: Equatable, Sendable {
    case checking
    /// The plugin does not run on native Windows Hosts.
    case unsupportedPlatform
    /// The Host could not be asked or did not answer usefully; nothing is
    /// known about the plugin, which is not the same as it being absent.
    case unavailable
    case notInstalled
    case installed(HeelerPluginInstallation)

    /// Maps one `Transport.readHeelerPlugin()` outcome.
    init(_ result: Result<HeelerPluginInstallation?, any Error>) {
        switch result {
        case .success(let installation?): self = .installed(installation)
        case .success(nil): self = .notInstalled
        case .failure(TransportError.hostFeatureUnavailable): self = .unsupportedPlatform
        case .failure: self = .unavailable
        }
    }

    /// One read over a transport the caller owns.
    static func read(over transport: any Transport) async -> HeelerPluginStatus {
        do {
            return HeelerPluginStatus(.success(try await transport.readHeelerPlugin()))
        } catch {
            return HeelerPluginStatus(.failure(error))
        }
    }

    /// The installed version when it is known to be current: enabled, read
    /// from a fresh manifest, and parseable.
    var confirmedVersion: PluginVersion? {
        guard case .installed(let installation) = self, installation.isEnabled,
            !installation.hasManifestWarning
        else { return nil }
        return installation.parsedVersion
    }

    /// The `features` this Host's confirmed plugin lacks; empty when they
    /// all work or the version is not known well enough to say.
    func requirements(for features: [HeelerPluginFeature]) -> [HeelerPluginRequirement] {
        guard let version = confirmedVersion else { return [] }
        return HeelerPluginFeature.requirements(features, installed: version)
    }

    /// Notification settings' notes for one registered Host. Live Activity
    /// notes apply only while its Live Activity is on.
    func notificationRequirements(liveActivityEnabled: Bool) -> [HeelerPluginRequirement] {
        requirements(
            for: [.sessionScopedNotifications]
                + (liveActivityEnabled ? [.liveActivityUpdates, .liveActivityRows] : []))
    }
}

/// Host detail copy for the plugin row and, when the user has something to
/// do, the notice with the commands that do it.
struct HeelerPluginPresentation: Equatable {
    struct Notice: Equatable {
        enum Tone: Equatable {
            case warning
            case info
        }

        let tone: Tone
        let message: String
        /// Shell commands to run on the Host, in order.
        let commands: [String]
        /// Follow-up sentences: features the current plugin lacks, and
        /// anything to redo afterwards.
        let notes: [String]
    }

    static let installCommand = HostSetupGuide.pluginInstallCommand

    static func uninstallCommand(_ pluginID: String) -> String {
        "herdr plugin uninstall \(pluginID)"
    }

    static func enableCommand(_ pluginID: String) -> String {
        "herdr plugin enable \(pluginID)"
    }
    static let reenableNotificationsNote =
        "The current plugin keeps its own registrations, so turn Notifications back on "
        + "for this Host in Settings › Notifications afterwards."

    let value: String
    let notice: Notice?

    init(_ status: HeelerPluginStatus, bundled: PluginVersion = HeelerPluginCompatibility.bundled) {
        switch status {
        case .checking:
            value = "Checking…"
            notice = nil
        case .unsupportedPlatform:
            value = "Not supported on Windows"
            notice = nil
        case .unavailable:
            value = "Unknown"
            notice = nil
        case .notInstalled:
            value = "Not installed"
            notice = Notice(
                tone: .info,
                message: "Install the Heeler plugin for notifications, Live Activity updates, "
                    + "and herdr's sidebar fields.",
                commands: [Self.installCommand],
                notes: [])
        case .installed(let installation):
            let described = Self.describe(installation, bundled: bundled)
            value = described.value
            notice = described.notice
        }
    }

    private static func describe(
        _ installation: HeelerPluginInstallation, bundled: PluginVersion
    ) -> (value: String, notice: Notice?) {
        let version = installation.version.isEmpty ? "Unknown version" : installation.version
        let parsed = installation.parsedVersion
        let isOutdated = parsed.map { $0 < bundled } ?? false
        let isLocal = installation.source == .local
        let shownValue = isLocal ? "\(version) · Linked locally" : version
        let missing = parsed.map {
            HeelerPluginFeature.requirements(installed: $0).map(\.note)
        } ?? []

        if installation.isLegacyID {
            // Installing next to the old id would run both plugins' hooks.
            return (
                version,
                Notice(
                    tone: .warning,
                    message: "This Host runs an old Heeler plugin under its former name. "
                        + "Remove it, then install the current plugin.",
                    commands: [uninstallCommand(installation.pluginID), installCommand],
                    notes: missing + [reenableNotificationsNote]))
        }
        if !installation.leftoverLegacyIDs.isEmpty {
            let removals = installation.leftoverLegacyIDs.map(uninstallCommand)
            return (
                shownValue,
                Notice(
                    tone: .warning,
                    message: "An old copy of the Heeler plugin is still installed under its "
                        + "former name and may send duplicate notifications. Remove it"
                        + (isOutdated && !isLocal ? " and update the plugin:" : ":"),
                    commands: removals + (isOutdated && !isLocal ? [installCommand] : []),
                    notes: missing))
        }
        if !installation.isEnabled {
            // Install registers the plugin enabled, so one command does both.
            if isOutdated, !isLocal, let parsed {
                return (
                    "\(version) · Disabled",
                    Notice(
                        tone: .warning,
                        message: "The Heeler plugin is disabled and out of date: \(parsed) → "
                            + "\(bundled). Installing the update also turns it on:",
                        commands: [installCommand],
                        notes: missing))
            }
            return (
                "\(version) · Disabled",
                Notice(
                    tone: .warning,
                    message: "The Heeler plugin is disabled, so this Host sends no notifications "
                        + "or Live Activity updates.",
                    commands: [enableCommand(installation.pluginID)],
                    notes: []))
        }
        if installation.hasManifestWarning {
            return (
                shownValue,
                Notice(
                    tone: .warning,
                    message: "herdr could not read the plugin's manifest, so its version may be "
                        + (isLocal ? "out of date. Check the linked checkout." : "out of date. Reinstall it."),
                    commands: isLocal ? [] : [installCommand],
                    notes: []))
        }
        guard isOutdated, let parsed else { return (shownValue, nil) }
        if isLocal {
            // `herdr plugin install` refuses to replace a linked plugin.
            return (
                shownValue,
                Notice(
                    tone: .warning,
                    message: "Plugin \(bundled) is available. This plugin is linked from a local "
                        + "checkout; update that checkout to \(bundled) or newer.",
                    commands: [],
                    notes: missing))
        }
        return (
            shownValue,
            Notice(
                tone: .warning,
                message: "Update available: \(parsed) → \(bundled). Run this on the Host:",
                commands: [installCommand],
                notes: missing))
    }
}
