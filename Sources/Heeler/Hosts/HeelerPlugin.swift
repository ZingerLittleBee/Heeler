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
    /// plugin (the plugin branch moved ahead of this build) counts as current.
    static let bundled = PluginVersion(0, 7, 1)
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
    /// Host-side Usage Limits and Token Usage.
    case usage

    var minimumVersion: PluginVersion {
        switch self {
        case .sidebarFields, .liveActivityUpdates: PluginVersion(0, 4, 0)
        case .liveActivityRows: PluginVersion(0, 5, 0)
        case .sessionScopedNotifications: PluginVersion(0, 6, 0)
        case .usage: PluginVersion(0, 7, 0)
        }
    }

    func isSupported(by version: PluginVersion) -> Bool {
        version >= minimumVersion
    }

    /// What the user loses with `installed`, and which version restores it.
    func requirementNote(installed: PluginVersion) -> String {
        switch self {
        case .usage:
            "Usage needs plugin \(minimumVersion) or newer; this Host has \(installed)."
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

/// One change Heeler can make to a Host's plugin itself, over the Host's
/// connection: the typed counterpart of a notice command. Plugin ids are
/// always `PluginListResult.knownIDs` literals, never Host text.
enum HeelerPluginStep: Equatable, Sendable {
    /// `herdr plugin install` from the plugin branch, which also updates a
    /// GitHub install in place.
    case install
    /// Removes an old copy installed under a legacy id.
    case uninstall(pluginID: String)
    /// Turns the plugin on in the Host's own session.
    case enable(pluginID: String)

    /// The herdr CLI arguments for the steps that run the CLI; enable goes
    /// through the session's `plugin.enable` request instead.
    var herdrArguments: [String]? {
        switch self {
        case .install: HostSetupGuide.pluginInstallArguments
        case .uninstall(let pluginID): ["plugin", "uninstall", pluginID]
        case .enable: nil
        }
    }
}

/// Why running a notice action left the plugin sheet with something to do,
/// in the sheet's words.
struct HeelerPluginActionFailure: Equatable, Sendable {
    let message: String
    /// herdr's own output, when it said why.
    let detail: String?

    init(message: String, detail: String? = nil) {
        self.message = message
        self.detail = detail
    }

    init(_ error: any Error) {
        switch error {
        case let error as HeelerPluginStepError:
            if let problem = error.nodeProblem {
                self.init(problem)
                return
            }
            let message =
                if error.needsServerRestart {
                    "herdr on the Host is newer than its running server. Restart the herdr "
                        + "server, then try again."
                } else if error.isBuildFailure {
                    "The plugin's build step (npm ci) failed on the Host. Check that SSH "
                        + "commands there find Node.js 20 or newer and npm."
                } else if error.isDownloadFailure {
                    "herdr could not download the plugin. Check that the Host can reach "
                        + "github.com."
                } else if case .uninstall = error.step {
                    "herdr could not remove the old copy of the plugin."
                } else {
                    "herdr could not install the plugin."
                }
            self.init(message: message, detail: error.detail())
        case TransportError.timedOut:
            self.init(
                message: "The Host did not finish in time. The change may still complete "
                    + "there, so run the checks again in a minute.")
        case let error as TransportError:
            self.init(message: error.presentation.message)
        case let error as HerdrAPIError:
            self.init(
                message: "herdr could not turn the plugin on.",
                detail: "\(error.code): \(error.message)")
        default:
            self.init(message: "The change failed unexpectedly. (\(error))")
        }
    }

    private init(_ problem: NodeToolchainProblem) {
        switch problem {
        case .missing:
            self.init(
                message: "Heeler could not find Node.js \(NodeToolchainProbe.minimumMajorVersion) "
                    + "or newer on the Host, so nothing changed. Install it, or make it the "
                    + "default version in your version manager, then try again.",
                detail: "Looked in \(NodeToolchainProbe.searchedPlaces).")
        case .tooOld(let version):
            self.init(
                message: "The Node.js Heeler found on the Host is \(version), and the "
                    + "plugin needs \(NodeToolchainProbe.minimumMajorVersion) or newer, so nothing "
                    + "changed. Install a newer version or make it the default, then try again.")
        case .npmMissing(let nodeVersion):
            self.init(
                message: "The Host has Node.js \(nodeVersion) but no npm, so nothing changed. "
                    + "Install npm (a separate package on Debian and Ubuntu), then try again.")
        }
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

        /// The notice's commands as steps Heeler can run for the user.
        struct Action: Equatable {
            let title: String
            let steps: [HeelerPluginStep]
        }

        let tone: Tone
        let message: String
        /// Shell commands to run on the Host, in order.
        let commands: [String]
        /// Follow-up sentences: features the current plugin lacks, and
        /// anything to redo afterwards.
        let notes: [String]
        /// nil when the user has to act on the Host: an install over a plugin
        /// that is not a GitHub install of this repository, or a change of
        /// the plugin's id, which Notification Registration only follows
        /// after reconnecting.
        var action: Action? = nil
    }

    /// Names the Host's session like the step the action runs, whose
    /// protocol check asks that session's server.
    static func installCommand(session: String, endpoint: HerdrEndpoint?) -> String {
        guard let endpoint else {
            // As the Setup Guide shows it: the repository's `/` reads alike
            // in every shell, though `render` would quote it.
            return ([HerdrCommandLine.render(session: session, arguments: [])]
                + HostSetupGuide.pluginInstallArguments).joined(separator: " ")
        }
        return HerdrCommandLine.render(
            session: session, endpoint: endpoint, arguments: HostSetupGuide.pluginInstallArguments)
    }

    static func uninstallCommand(
        _ pluginID: String, session: String, endpoint: HerdrEndpoint?
    ) -> String {
        HerdrCommandLine.render(
            session: session, endpoint: endpoint, arguments: ["plugin", "uninstall", pluginID])
    }

    /// `herdr plugin enable` asks a herdr server, so the command names the
    /// session the Host targets: `session` is the Host's session name, blank
    /// for the default session.
    static func enableCommand(
        _ pluginID: String, session: String, endpoint: HerdrEndpoint?
    ) -> String {
        HerdrCommandLine.render(
            session: session, endpoint: endpoint, arguments: ["plugin", "enable", pluginID])
    }
    static let reenableNotificationsNote =
        "The current plugin keeps its own registrations, so turn Notifications back on "
        + "for this Host in Settings › Notifications afterwards."

    let value: String
    let notice: Notice?

    /// `session` is the Host's herdr session name, as for `enableCommand`.
    init(
        _ status: HeelerPluginStatus, session: String, endpoint: HerdrEndpoint? = nil,
        bundled: PluginVersion = HeelerPluginCompatibility.bundled
    ) {
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
                commands: [Self.installCommand(session: session, endpoint: endpoint)],
                notes: [],
                action: Notice.Action(title: "Install Plugin", steps: [.install]))
        case .installed(let installation):
            let described = Self.describe(
                installation, session: session, endpoint: endpoint, bundled: bundled)
            value = described.value
            notice = described.notice
        }
    }

    private static func describe(
        _ installation: HeelerPluginInstallation, session: String,
        endpoint: HerdrEndpoint?, bundled: PluginVersion
    ) -> (value: String, notice: Notice?) {
        let installCommand = Self.installCommand(session: session, endpoint: endpoint)
        let version = installation.version.isEmpty ? "Unknown version" : installation.version
        let parsed = installation.parsedVersion
        let isOutdated = parsed.map { $0 < bundled } ?? false
        let isLocal = installation.source == .local
        let shownValue = isLocal ? "\(version) · Linked locally" : version
        let missing = parsed.map {
            HeelerPluginFeature.requirements(
                HeelerPluginFeature.allCases.filter { $0.minimumVersion <= bundled },
                installed: $0).map(\.note)
        } ?? []

        if installation.isLegacyID {
            // Installing next to the old id would run both plugins' hooks.
            if let currentSource = installation.disabledCurrentIDSource {
                // Neither removing the old id nor, on herdr 0.9.4, a
                // reinstall turns the current plugin on, and `herdr plugin
                // install` refuses to replace a linked one.
                let reinstalls = currentSource != .local
                let enable = enableCommand(
                    SSHTransportSettings.notificationPluginID, session: session, endpoint: endpoint)
                return (
                    version,
                    Notice(
                        tone: .warning,
                        message: "This Host runs an old Heeler plugin under its former name, and the "
                            + "current plugin is disabled. Remove the old copy, then "
                            + (reinstalls
                                ? "install the current plugin and turn it on."
                                : "turn the current plugin on."),
                        commands: [uninstallCommand(
                            installation.pluginID, session: session, endpoint: endpoint)]
                            + (reinstalls ? [installCommand, enable] : [enable]),
                        notes: missing + [reenableNotificationsNote]))
            }
            return (
                version,
                Notice(
                    tone: .warning,
                    message: "This Host runs an old Heeler plugin under its former name. "
                        + "Remove it, then install the current plugin.",
                    commands: [
                        uninstallCommand(installation.pluginID, session: session, endpoint: endpoint),
                        installCommand,
                    ],
                    notes: missing + [reenableNotificationsNote]))
        }
        if !installation.leftoverLegacyIDs.isEmpty {
            let removals = installation.leftoverLegacyIDs.map {
                uninstallCommand($0, session: session, endpoint: endpoint)
            }
            let updates = isOutdated && !isLocal
            // The action updates first, so a failed update leaves the Host
            // as it was.
            return (
                shownValue,
                Notice(
                    tone: .warning,
                    message: "An old copy of the Heeler plugin is still installed under its "
                        + "former name and may send duplicate notifications. Remove it"
                        + (updates ? " and update the plugin:" : ":"),
                    commands: removals + (updates ? [installCommand] : []),
                    notes: missing,
                    action: action(
                        updates ? "Update Plugin" : "Remove Old Copy", for: installation,
                        steps: (updates ? [.install] : [])
                            + installation.leftoverLegacyIDs.map { .uninstall(pluginID: $0) })))
        }
        if !installation.isEnabled {
            // A reinstall keeps a disabled plugin disabled on herdr 0.9.4,
            // while 0.9.3 turned it back on, and the Host's herdr command
            // line decides, not its server. So the update is followed by
            // enable, which also succeeds on an enabled plugin.
            if isOutdated, !isLocal, let parsed {
                return (
                    "\(version) · Disabled",
                    Notice(
                        tone: .warning,
                        message: "The Heeler plugin is disabled and out of date: \(parsed) → "
                            + "\(bundled). Update it, then turn it on:",
                        commands: [installCommand, enableCommand(
                            installation.pluginID, session: session, endpoint: endpoint)],
                        notes: missing,
                        action: action(
                            "Update and Turn On", for: installation,
                            steps: [.install, .enable(pluginID: installation.pluginID)])))
            }
            return (
                "\(version) · Disabled",
                Notice(
                    tone: .warning,
                    message: "The Heeler plugin is disabled, so this Host sends no notifications "
                        + "or Live Activity updates.",
                    commands: [enableCommand(installation.pluginID, session: session, endpoint: endpoint)],
                    notes: [],
                    action: action(
                        "Turn On Plugin", for: installation,
                        steps: [.enable(pluginID: installation.pluginID)])))
        }
        if installation.hasManifestWarning {
            return (
                shownValue,
                Notice(
                    tone: .warning,
                    message: "herdr could not read the plugin's manifest, so its version may be "
                        + (isLocal ? "out of date. Check the linked checkout." : "out of date. Reinstall it."),
                    // No action: the version herdr reports from its
                    // registry may be stale, so a reinstall could be a
                    // downgrade the app cannot see.
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
                notes: missing,
                action: action("Update Plugin", for: installation, steps: [.install])))
    }

    /// `steps` as a notice action, unless they install over a plugin that is
    /// not ``HeelerPluginInstallation/isReplaceableByInstall``.
    private static func action(
        _ title: String, for installation: HeelerPluginInstallation, steps: [HeelerPluginStep]
    ) -> Notice.Action? {
        guard installation.isReplaceableByInstall || !steps.contains(.install) else { return nil }
        return Notice.Action(title: title, steps: steps)
    }
}
