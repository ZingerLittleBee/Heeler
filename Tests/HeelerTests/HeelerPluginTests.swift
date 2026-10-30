import Foundation
import HeelerSSH
import Testing

@testable import Heeler

@Suite("Heeler plugin version")
struct HeelerPluginVersionTests {
    @Test(arguments: [
        ("0.6.0", PluginVersion(0, 6, 0)),
        ("1.12.3", PluginVersion(1, 12, 3)),
        ("0.6", PluginVersion(0, 6, 0)),
        ("0.7.0-beta.1", PluginVersion(0, 7, 0)),
        ("0.7.0+abc", PluginVersion(0, 7, 0)),
    ])
    func parsesReleaseNumbers(raw: String, expected: PluginVersion) {
        #expect(PluginVersion(raw) == expected)
    }

    @Test(arguments: ["", "0", "v0.6.0", "0.6.0.1", "0..6", "0.6.x", "-1.0.0", " 0.6.0", "０.6.0"])
    func rejectsAnythingElse(raw: String) {
        #expect(PluginVersion(raw) == nil)
    }

    @Test func comparesNumericallyByComponent() {
        #expect(PluginVersion(0, 5, 9) < PluginVersion(0, 6, 0))
        #expect(PluginVersion(0, 10, 0) > PluginVersion(0, 9, 3))
        #expect(PluginVersion(1, 0, 0) > PluginVersion(0, 99, 99))
        #expect(PluginVersion(0, 6, 0).description == "0.6.0")
    }

    /// The plugin's Node tests pin herdr-plugin.toml to the same vector, so a
    /// plugin release cannot leave the app recommending the previous one.
    @Test func bundledVersionMatchesTheSharedVector() throws {
        struct Vector: Decodable { let version: String }
        let url = try #require(
            Bundle(for: BundleLocator.self).url(forResource: "plugin-version-v1", withExtension: "json"))
        let vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
        #expect(PluginVersion(vector.version) == HeelerPluginCompatibility.bundled)
        #expect(HeelerPluginCompatibility.bundled.description == vector.version)
        for feature in HeelerPluginFeature.allCases {
            #expect(feature.minimumVersion <= HeelerPluginCompatibility.bundled)
        }
    }

    private final class BundleLocator {}
}

@Suite("Heeler plugin list result")
struct HeelerPluginListResultTests {
    /// herdr 0.9.3's `plugin.list` answer for a linked checkout, trimmed of
    /// nothing: manifest arrays and all.
    private static let liveResponse = #"""
        {"id":"r1","result":{"plugins":[{"actions":[{"command":["node","src/pair-action.js"],"contexts":["global"],"description":"Show a Pairing Code QR for the Heeler app","id":"pair","title":"Pair a mobile device"}],"build":[{"command":["npm","ci"]}],"description":"Pair a Heeler device by scanning a QR Pairing Code","enabled":true,"events":[{"command":["node","src/activity-hook.js"],"on":"pane.agent_status_changed"}],"manifest_path":"/u/Heeler/plugin/herdr-plugin.toml","min_herdr_version":"0.7.5","name":"heeler","panes":[{"command":["node","src/pair-popup.js"],"height":"100%","id":"pair","placement":"popup","title":"Pair device","width":"100%"}],"platforms":["linux","macos"],"plugin_id":"heeler","plugin_root":"/u/Heeler/plugin","source":{"kind":"local"},"startup":[{"command":["node","src/sidebar-hook.js"]}],"version":"0.6.0"}],"type":"plugin_list"}}
        """#

    private func decode(_ plugins: String) throws -> HeelerPluginInstallation? {
        let line = #"{"id":"r1","result":{"type":"plugin_list","plugins":["# + plugins + "]}}"
        return HeelerPluginInstallation(
            try HerdrWire.decodeResult(
                PluginListResult.self, fromResponseLine: Data(line.utf8), requestID: "r1"))
    }

    @Test func decodesHerdrsLiveAnswer() throws {
        let result = try HerdrWire.decodeResult(
            PluginListResult.self, fromResponseLine: Data(Self.liveResponse.utf8), requestID: "r1")
        #expect(
            HeelerPluginInstallation(result)
                == HeelerPluginInstallation(
                    pluginRoot: "/u/Heeler/plugin", version: "0.6.0", source: .local, repository: nil))
    }

    @Test func prefersTheCurrentIDAndIgnoresOtherPlugins() throws {
        let installation = try decode(
            #"{"plugin_id":"other","version":"9.9.9"},"#
                + #"{"plugin_id":"heeler","version":"0.5.0","source":{"kind":"github"}}"#)
        #expect(installation == HeelerPluginInstallation(version: "0.5.0", repository: nil))
    }

    /// Both run their hooks, so the leftover is worth naming.
    @Test func anEnabledLegacyIDBesideTheCurrentOneIsALeftover() throws {
        let installation = try decode(
            #"{"plugin_id":"herdr-mobile.pairing","version":"0.3.0","source":{"kind":"github"}},"#
                + #"{"plugin_id":"heeler","version":"0.6.0","source":{"kind":"github"}}"#)
        #expect(
            installation
                == HeelerPluginInstallation(
                    version: "0.6.0", leftoverLegacyIDs: ["herdr-mobile.pairing"],
                    repository: nil))
        let disabledLegacy = try decode(
            #"{"plugin_id":"herdr-mobile.pairing","version":"0.3.0","enabled":false},"#
                + #"{"plugin_id":"heeler","version":"0.6.0","source":{"kind":"github"}}"#)
        #expect(disabledLegacy?.leftoverLegacyIDs == [])
    }

    /// herdr runs hooks only for enabled plugins, and registration follows
    /// the enabled one, so a disabled current id must not hide it.
    @Test func anEnabledLegacyIDOutranksADisabledCurrentOne() throws {
        let installation = try #require(
            try decode(
                #"{"plugin_id":"heeler","version":"0.6.0","enabled":false},"#
                    + #"{"plugin_id":"herdr-mobile.pairing","version":"0.3.0"}"#))
        #expect(installation.pluginID == "herdr-mobile.pairing")
        #expect(installation.isEnabled)
        let result = PluginListResult(plugins: [
            .init(pluginID: "heeler", version: "0.6.0", enabled: false, source: nil, warnings: nil),
            .init(pluginID: "herdr-mobile.pairing", version: nil, enabled: nil, source: nil, warnings: nil),
        ])
        #expect(result.heelerEntry(enabledOnly: true)?.pluginID == "herdr-mobile.pairing")
        #expect(
            PluginListResult(plugins: [result.plugins[0]]).heelerEntry(enabledOnly: true) == nil)
    }

    /// Once the former id is removed, the disabled current id is the plugin
    /// to turn on, and its source says whether reinstalling can replace it.
    @Test func aDisabledCurrentIDBesideAnEnabledLegacyIDIsRecorded() throws {
        let github = try #require(
            try decode(
                #"{"plugin_id":"heeler","version":"0.6.0","enabled":false,"source":{"kind":"github"}},"#
                    + #"{"plugin_id":"herdr-mobile.pairing","version":"0.3.0"}"#))
        #expect(github.pluginID == "herdr-mobile.pairing")
        #expect(github.disabledCurrentIDSource == .github)
        let linked = try #require(
            try decode(
                #"{"plugin_id":"heeler","version":"0.6.0","enabled":false,"source":{"kind":"local"}},"#
                    + #"{"plugin_id":"herdr-mobile.pairing","version":"0.3.0"}"#))
        #expect(linked.disabledCurrentIDSource == .local)
    }

    @Test(arguments: [
        // The former id alone.
        #"{"plugin_id":"herdr-mobile.pairing","version":"0.3.0"}"#,
        // Both enabled: the current id runs, beside a leftover.
        #"{"plugin_id":"herdr-mobile.pairing","version":"0.3.0"},"#
            + #"{"plugin_id":"heeler","version":"0.6.0","enabled":true}"#,
        // A missing `enabled` reads as enabled.
        #"{"plugin_id":"herdr-mobile.pairing","version":"0.3.0"},"#
            + #"{"plugin_id":"heeler","version":"0.6.0"}"#,
        // With no enabled former id, the disabled current id is the entry
        // itself and already reads as disabled.
        #"{"plugin_id":"heeler","version":"0.6.0","enabled":false}"#,
        #"{"plugin_id":"herdr-mobile.pairing","version":"0.3.0","enabled":false},"#
            + #"{"plugin_id":"heeler","version":"0.6.0","enabled":false}"#,
    ])
    func noDisabledCurrentIDIsRecordedOtherwise(plugins: String) throws {
        let installation = try #require(try decode(plugins))
        #expect(installation.disabledCurrentIDSource == nil)
    }

    @Test func reportsALegacyIDAndADisabledPluginRatherThanCallingThemAbsent() throws {
        let legacy = try #require(
            try decode(#"{"plugin_id":"herdr-mobile.pairing","version":"0.3.0","enabled":false}"#))
        #expect(legacy.isLegacyID)
        #expect(!legacy.isEnabled)
        #expect(legacy.source == .unknown)
    }

    @Test func readsAnEmptyListAsNotInstalled() throws {
        #expect(try decode("") == nil)
        #expect(try decode(#"{"plugin_id":"other","version":"1.0.0"}"#) == nil)
    }

    @Test func toleratesMissingFieldsAndFlagsAStaleManifest() throws {
        let installation = try #require(
            try decode(
                #"{"plugin_id":"heeler","warnings":["manifest unavailable: missing file"]}"#))
        #expect(installation.version == "")
        #expect(installation.isEnabled)
        #expect(installation.hasManifestWarning)
        let unrelatedWarning = try #require(
            try decode(#"{"plugin_id":"heeler","version":"0.6.0","warnings":["slow build"]}"#))
        #expect(!unrelatedWarning.hasManifestWarning)
    }
}

@Suite("Heeler plugin presentation")
struct HeelerPluginPresentationTests {
    private let install = HostSetupGuide.pluginInstallCommand

    @Test func endpointRecoveryCommandsKeepTheInstanceForEveryOperation() throws {
        let endpoint = try #require(HerdrEndpoint(
            socketPath: "/tmp/custom herdr/herdr/sessions/work/herdr.sock",
            executablePath: "/tmp/custom herdr/bin/launch"))
        let notice = try #require(HeelerPluginPresentation(
            .installed(HeelerPluginInstallation(
                pluginID: "herdr-mobile.pairing", version: "0.3.0",
                disabledCurrentIDSource: .github)),
            session: "wrong", endpoint: endpoint).notice)
        let prefix = #"/bin/sh -c 'export HERDR_SOCKET_PATH="$1"; shift; exec "$@"' herdr '/tmp/custom herdr/herdr/sessions/work/herdr.sock' '/tmp/custom herdr/bin/launch' "#
        #expect(notice.commands == [
            prefix + "plugin uninstall herdr-mobile.pairing",
            prefix + "plugin install 'ZingerLittleBee/Heeler' --ref plugin --yes",
            prefix + "plugin enable heeler",
        ])
        #expect(try #require(HeelerPluginPresentation(
            .notInstalled, session: "", endpoint: endpoint).notice).commands == [notice.commands[1]])
    }

    @Test func statesWithNothingToDoShowOnlyTheValue() {
        let cases: [(HeelerPluginStatus, String)] = [
            (.checking, "Checking…"),
            (.unsupportedPlatform, "Not supported on Windows"),
            (.unsupportedBackend, "Not supported on herdr-core"),
            (.unavailable, "Unknown"),
            (.installed(HeelerPluginInstallation(version: "0.6.0")), "0.6.0"),
            // The plugin branch moved ahead of this build.
            (.installed(HeelerPluginInstallation(version: "0.7.0")), "0.7.0"),
            (.installed(HeelerPluginInstallation(version: "0.6.0", source: .local)), "0.6.0 · Linked locally"),
            // Unparseable: nothing to compare, so nothing to recommend.
            (.installed(HeelerPluginInstallation(version: "dev")), "dev"),
            (.installed(HeelerPluginInstallation(version: "")), "Unknown version"),
        ]
        for (status, value) in cases {
            let presentation = HeelerPluginPresentation(status, session: "", bundled: PluginVersion(0, 6, 0))
            #expect(presentation.value == value)
            #expect(presentation.notice == nil, "\(status)")
        }
    }

    @Test func anOlderGitHubPluginGetsTheInstallCommandAndWhatItLacks() throws {
        let presentation = HeelerPluginPresentation(
            .installed(HeelerPluginInstallation(version: "0.4.0")),
            session: "", bundled: PluginVersion(0, 6, 0))
        let notice = try #require(presentation.notice)
        #expect(presentation.value == "0.4.0")
        #expect(notice.tone == .warning)
        #expect(notice.message.contains("0.4.0 → 0.6.0"))
        #expect(notice.commands == [install])
        #expect(notice.notes == [
            HeelerPluginFeature.liveActivityRows.requirementNote(installed: PluginVersion(0, 4, 0)),
            HeelerPluginFeature.sessionScopedNotifications.requirementNote(
                installed: PluginVersion(0, 4, 0)),
        ])
    }

    @Test func anUnknownSourceStillGetsTheInstallCommand() throws {
        let presentation = HeelerPluginPresentation(
            .installed(HeelerPluginInstallation(version: "0.5.0", source: .unknown)),
            session: "", bundled: PluginVersion(0, 6, 0))
        #expect(try #require(presentation.notice).commands == [install])
    }

    /// `herdr plugin install` refuses to replace a linked plugin.
    @Test func anOlderLinkedPluginGetsNoInstallCommand() throws {
        let notice = try #require(
            HeelerPluginPresentation(
                .installed(HeelerPluginInstallation(version: "0.5.0", source: .local)),
                session: "", bundled: PluginVersion(0, 6, 0)
            ).notice)
        #expect(notice.commands.isEmpty)
        #expect(notice.message.contains("local checkout"))
        #expect(notice.notes.count == 1)
    }

    /// Installing beside the old id would leave both plugins' hooks running.
    @Test func aLegacyIDIsRemovedBeforeInstallingEvenWhenDisabled() throws {
        let presentation = HeelerPluginPresentation(
            .installed(
                HeelerPluginInstallation(
                    pluginID: "herdr-mobile.pairing", version: "0.3.0", isEnabled: false,
                    source: .github)),
            session: "", bundled: PluginVersion(0, 6, 0))
        let notice = try #require(presentation.notice)
        #expect(notice.commands == ["herdr plugin uninstall herdr-mobile.pairing", install])
        // Background updates' row note folds into the updates note, and the
        // old plugin's registrations do not carry over.
        #expect(notice.notes.count == 4)
        #expect(notice.notes.last == HeelerPluginPresentation.reenableNotificationsNote)
    }

    /// The current plugin stays disabled once the former id is gone, and a
    /// reinstall on herdr 0.9.4 keeps it so.
    @Test func aDisabledCurrentIDIsTurnedOnAfterTheLegacyIDGoes() throws {
        let notice = try #require(
            HeelerPluginPresentation(
                .installed(
                    HeelerPluginInstallation(
                        pluginID: "herdr-mobile.pairing", version: "0.3.0",
                        disabledCurrentIDSource: .github)),
                session: "work", bundled: PluginVersion(0, 6, 0)
            ).notice)
        #expect(
            notice.message
                == "This Host runs an old Heeler plugin under its former name, and the current "
                + "plugin is disabled. Remove the old copy, then install the current plugin "
                + "and turn it on.")
        #expect(
            notice.commands == [
                "herdr --session work plugin uninstall herdr-mobile.pairing",
                "herdr --session work plugin install ZingerLittleBee/Heeler --ref plugin --yes",
                "herdr --session work plugin enable heeler",
            ])
        #expect(notice.notes.count == 4)
        #expect(notice.notes.last == HeelerPluginPresentation.reenableNotificationsNote)
    }

    /// `herdr plugin install` refuses to replace a linked plugin.
    @Test func aDisabledLinkedCurrentIDIsOnlyTurnedOnAfterTheLegacyIDGoes() throws {
        let notice = try #require(
            HeelerPluginPresentation(
                .installed(
                    HeelerPluginInstallation(
                        pluginID: "herdr-mobile.pairing", version: "0.3.0",
                        disabledCurrentIDSource: .local)),
                session: "", bundled: PluginVersion(0, 6, 0)
            ).notice)
        #expect(
            notice.message
                == "This Host runs an old Heeler plugin under its former name, and the current "
                + "plugin is disabled. Remove the old copy, then turn the current plugin on.")
        #expect(
            notice.commands == [
                "herdr plugin uninstall herdr-mobile.pairing", "herdr plugin enable heeler",
            ])
    }

    @Test func aLeftoverLegacyIDIsRemovedAndAnUpdateFoldedIn() throws {
        let current = try #require(
            HeelerPluginPresentation(
                .installed(
                    HeelerPluginInstallation(
                        version: "0.6.0", leftoverLegacyIDs: ["herdr-mobile.pairing"])),
                session: "", bundled: PluginVersion(0, 6, 0)
            ).notice)
        #expect(current.commands == ["herdr plugin uninstall herdr-mobile.pairing"])
        let outdated = try #require(
            HeelerPluginPresentation(
                .installed(
                    HeelerPluginInstallation(
                        version: "0.5.0", leftoverLegacyIDs: ["herdr-mobile.pairing"])),
                session: "", bundled: PluginVersion(0, 6, 0)
            ).notice)
        #expect(outdated.commands == ["herdr plugin uninstall herdr-mobile.pairing", install])
    }

    /// herdr 0.9.4 keeps a disabled plugin disabled when it is reinstalled,
    /// while 0.9.3 turned it back on, so the update is always followed by
    /// the enable command.
    @Test func aDisabledOutdatedPluginIsUpdatedThenTurnedOn() throws {
        let presentation = HeelerPluginPresentation(
            .installed(HeelerPluginInstallation(version: "0.5.0", isEnabled: false)),
            session: "", bundled: PluginVersion(0, 6, 0))
        #expect(presentation.value == "0.5.0 · Disabled")
        let notice = try #require(presentation.notice)
        #expect(
            notice.message
                == "The Heeler plugin is disabled and out of date: 0.5.0 → 0.6.0. "
                + "Update it, then turn it on:")
        #expect(notice.commands == [install, "herdr plugin enable heeler"])
        #expect(notice.notes.count == 1)
    }

    /// `herdr plugin install` refuses to replace a linked plugin.
    @Test func aDisabledLinkedPluginIsOnlyTurnedOnEvenWhenOutdated() throws {
        let linked = try #require(
            HeelerPluginPresentation(
                .installed(
                    HeelerPluginInstallation(version: "0.5.0", isEnabled: false, source: .local)),
                session: "work", bundled: PluginVersion(0, 6, 0)
            ).notice)
        #expect(linked.commands == ["herdr --session work plugin enable heeler"])
    }

    /// The commands are the ones the action runs, which name the Host's
    /// session: enable asks that session's server, and install and uninstall
    /// check its protocol first, though they write the shared registry.
    @Test func everyCommandNamesTheHostsSession() throws {
        let notice = try #require(
            HeelerPluginPresentation(
                .installed(HeelerPluginInstallation(version: "0.5.0", isEnabled: false)),
                session: "work", bundled: PluginVersion(0, 6, 0)
            ).notice)
        #expect(
            notice.commands == [
                "herdr --session work plugin install ZingerLittleBee/Heeler --ref plugin --yes",
                "herdr --session work plugin enable heeler",
            ])
        let legacy = try #require(
            HeelerPluginPresentation(
                .installed(HeelerPluginInstallation(
                    version: "0.6.0", leftoverLegacyIDs: ["herdr-mobile.pairing"])),
                session: "work", bundled: PluginVersion(0, 6, 0)
            ).notice)
        #expect(legacy.commands == ["herdr --session work plugin uninstall herdr-mobile.pairing"])
        #expect(
            HeelerPluginPresentation(.notInstalled, session: "work").notice?.commands
                == ["herdr --session work plugin install ZingerLittleBee/Heeler --ref plugin --yes"])
    }

    @Test func aDisabledPluginIsEnabledNotReinstalled() throws {
        let presentation = HeelerPluginPresentation(
            .installed(HeelerPluginInstallation(version: "0.6.0", isEnabled: false)),
            session: "", bundled: PluginVersion(0, 6, 0))
        #expect(presentation.value == "0.6.0 · Disabled")
        #expect(try #require(presentation.notice).commands == ["herdr plugin enable heeler"])
        let named = try #require(
            HeelerPluginPresentation(
                .installed(HeelerPluginInstallation(version: "0.6.0", isEnabled: false)),
                session: "work", bundled: PluginVersion(0, 6, 0)
            ).notice)
        #expect(named.commands == ["herdr --session work plugin enable heeler"])
    }

    @Test func aStaleManifestAsksForAReinstallUnlessLinked() throws {
        let github = try #require(
            HeelerPluginPresentation(
                .installed(HeelerPluginInstallation(version: "0.6.0", hasManifestWarning: true)),
                session: "", bundled: PluginVersion(0, 6, 0)
            ).notice)
        #expect(github.commands == [install])
        // herdr's registry version may be stale, so a reinstall could be a
        // downgrade the app cannot see.
        #expect(github.action == nil)
        let linked = try #require(
            HeelerPluginPresentation(
                .installed(
                    HeelerPluginInstallation(
                        version: "0.6.0", source: .local, hasManifestWarning: true)),
                session: "", bundled: PluginVersion(0, 6, 0)
            ).notice)
        #expect(linked.commands.isEmpty)
    }

    @Test func corePluginFailureDoesNotOfferATuiInstallOrClaimWindows() {
        let status = HeelerPluginStatus(.failure(HeelerPluginUnavailableError.herdrCore))
        #expect(status == .unsupportedBackend)
        let presentation = HeelerPluginPresentation(status, session: "")
        #expect(presentation.value == "Not supported on herdr-core")
        #expect(presentation.notice == nil)
        #expect(status.confirmedVersion == nil)
    }

    @Test func notInstalledOffersTheInstallCommandCalmly() throws {
        let notice = try #require(HeelerPluginPresentation(.notInstalled, session: "").notice)
        #expect(notice.tone == .info)
        #expect(notice.commands == [install])
    }

    @Test(arguments: [
        ("0.3.0", true, [HeelerPluginFeature.sessionScopedNotifications, .liveActivityUpdates]),
        ("0.4.0", true, [.sessionScopedNotifications, .liveActivityRows]),
        ("0.5.0", true, [.sessionScopedNotifications]),
        ("0.3.0", false, [.sessionScopedNotifications]),
        ("0.6.0", true, []),
    ])
    func notificationSettingsNoteWhatTheHostLacks(
        version: String, liveActivity: Bool, expected: [HeelerPluginFeature]
    ) {
        let status = HeelerPluginStatus.installed(HeelerPluginInstallation(version: version))
        let requirements = status.notificationRequirements(liveActivityEnabled: liveActivity)
        #expect(requirements.map(\.feature) == expected)
        #expect(requirements.allSatisfy { $0.note.contains(version) })
    }

    /// Plugin 0.8.0 reports Accounts and reads the Account file the app
    /// writes; 0.7.x does neither, so the update notice names it.
    @Test func claudeCodeAccountsNeedPlugin080() throws {
        #expect(HeelerPluginFeature.claudeAccounts.minimumVersion == PluginVersion(0, 8, 0))
        #expect(!HeelerPluginFeature.claudeAccounts.isSupported(by: PluginVersion(0, 7, 1)))
        #expect(HeelerPluginFeature.claudeAccounts.isSupported(by: PluginVersion(0, 8, 0)))
        #expect(HeelerPluginFeature.claudeAccounts.isSupported(by: PluginVersion(0, 9, 0)))
        let status = HeelerPluginStatus.installed(HeelerPluginInstallation(version: "0.7.1"))
        #expect(
            status.requirements(for: [.usage, .claudeAccounts]).map(\.note)
                == ["Claude Code Accounts need plugin 0.8.0 or newer; this Host has 0.7.1."])
        let notice = try #require(
            HeelerPluginPresentation(status, session: "", bundled: PluginVersion(0, 8, 0)).notice)
        #expect(notice.message.contains("0.7.1 → 0.8.0"))
        #expect(notice.notes == ["Claude Code Accounts need plugin 0.8.0 or newer; this Host has 0.7.1."])
        #expect(
            HeelerPluginStatus.installed(HeelerPluginInstallation(version: "0.8.0"))
                .requirements(for: HeelerPluginFeature.allCases).isEmpty)
    }

    @Test func requirementNotesNeedAConfirmedVersion() {
        let old = HeelerPluginStatus.installed(HeelerPluginInstallation(version: "0.3.0"))
        #expect(old.requirements(for: [.sidebarFields]).map(\.feature) == [.sidebarFields])
        #expect(
            HeelerPluginStatus.installed(HeelerPluginInstallation(version: "0.4.0"))
                .requirements(for: [.sidebarFields]).isEmpty)
        let unconfirmed: [HeelerPluginStatus] = [
            .checking, .unavailable, .notInstalled, .unsupportedPlatform, .unsupportedBackend,
            .installed(HeelerPluginInstallation(version: "0.3.0", isEnabled: false)),
            .installed(HeelerPluginInstallation(version: "0.3.0", hasManifestWarning: true)),
            .installed(HeelerPluginInstallation(version: "dev")),
        ]
        for status in unconfirmed {
            #expect(status.requirements(for: HeelerPluginFeature.allCases).isEmpty, "\(status)")
        }
    }
}

@Suite("Heeler plugin actions")
struct HeelerPluginActionTests {
    private func action(
        _ installation: HeelerPluginInstallation
    ) -> HeelerPluginPresentation.Notice.Action? {
        HeelerPluginPresentation(
            .installed(installation), session: "work", bundled: PluginVersion(0, 6, 0)
        ).notice?.action
    }

    @Test func eachNoticeHeelerCanRunCarriesItsSteps() {
        let cases: [(HeelerPluginInstallation, String, [HeelerPluginStep])] = [
            (HeelerPluginInstallation(version: "0.5.0"), "Update Plugin", [.install]),
            (
                HeelerPluginInstallation(version: "0.5.0", isEnabled: false),
                "Update and Turn On", [.install, .enable(pluginID: "heeler")]
            ),
            (
                HeelerPluginInstallation(version: "0.6.0", isEnabled: false),
                "Turn On Plugin", [.enable(pluginID: "heeler")]
            ),
            // A linked plugin is still turned on, just never reinstalled.
            (
                HeelerPluginInstallation(version: "0.5.0", isEnabled: false, source: .local),
                "Turn On Plugin", [.enable(pluginID: "heeler")]
            ),
            // The update runs before the removal, so a failed one changes nothing.
            (
                HeelerPluginInstallation(
                    version: "0.5.0", leftoverLegacyIDs: ["herdr-mobile.pairing"]),
                "Update Plugin", [.install, .uninstall(pluginID: "herdr-mobile.pairing")]
            ),
            (
                HeelerPluginInstallation(
                    version: "0.6.0", source: .local, leftoverLegacyIDs: ["herdr-mobile.pairing"]),
                "Remove Old Copy", [.uninstall(pluginID: "herdr-mobile.pairing")]
            ),
        ]
        for (installation, title, steps) in cases {
            #expect(
                action(installation)
                    == HeelerPluginPresentation.Notice.Action(title: title, steps: steps),
                "\(installation)")
        }
        #expect(
            HeelerPluginPresentation(.notInstalled, session: "").notice?.action
                == HeelerPluginPresentation.Notice.Action(title: "Install Plugin", steps: [.install]))
    }

    /// The user acts on the Host where herdr would refuse, where the plugin
    /// id changes under Notification Registration, or where the version is
    /// too uncertain to rule out a downgrade.
    @Test func noticesHeelerCannotRunHaveNoAction() throws {
        let installations = [
            HeelerPluginInstallation(version: "0.6.0", hasManifestWarning: true),
            HeelerPluginInstallation(version: "0.5.0", isEnabled: false, hasManifestWarning: true),
            HeelerPluginInstallation(
                version: "0.5.0", hasManifestWarning: true,
                leftoverLegacyIDs: ["herdr-mobile.pairing"]),
            HeelerPluginInstallation(version: "0.5.0", source: .local),
            HeelerPluginInstallation(version: "0.5.0", source: .unknown),
            HeelerPluginInstallation(version: "0.6.0", source: .local, hasManifestWarning: true),
            HeelerPluginInstallation(pluginID: "herdr-mobile.pairing", version: "0.3.0"),
            HeelerPluginInstallation(
                pluginID: "herdr-mobile.pairing", version: "0.3.0",
                disabledCurrentIDSource: .github),
        ]
        for installation in installations {
            let notice = try #require(
                HeelerPluginPresentation(
                    .installed(installation), session: "", bundled: PluginVersion(0, 6, 0)
                ).notice, "\(installation)")
            #expect(notice.action == nil, "\(installation)")
        }
    }

    /// An install finds Node.js first for its `npm ci` build; an uninstall
    /// builds nothing. scripts/test-node-toolchain-probe.py runs the probe.
    @Test func stepsRunHerdrWithTheNoticesArgumentsInTheHostsSession() {
        let install = HeelerPluginStep.install.herdrArguments ?? []
        #expect(
            HeelerSSHTransport.heelerPluginCommand(
                arguments: install, session: "", launcher: nil, findsNode: true)
                == "/bin/sh -c '\(HerdrHostPath.pathExport); "
                + "__h_herdr=$(command -v herdr) || exit 127; \(NodeToolchainProbe.script)"
                + #"exec "$__h_herdr" plugin install '\''ZingerLittleBee/Heeler'\'' --ref plugin --yes'"#)
        #expect(
            HeelerSSHTransport.heelerPluginCommand(
                arguments: ["plugin", "uninstall", "herdr-mobile.pairing"], session: "work",
                launcher: nil, findsNode: false)
                == "/bin/sh -c '\(HerdrHostPath.pathExport); exec herdr --session work plugin "
                + "uninstall herdr-mobile.pairing'")
        #expect(HeelerPluginStep.uninstall(pluginID: "herdr-mobile.pairing").herdrArguments
            == ["plugin", "uninstall", "herdr-mobile.pairing"])
        #expect(HeelerPluginStep.enable(pluginID: "heeler").herdrArguments == nil)
        // The probe sits inside single quotes.
        #expect(!NodeToolchainProbe.script.contains("'"))
    }

    /// The launcher runs with the endpoint's socket and no PATH prefixes (ADR
    /// 0023); an install still looks for Node.js before it.
    @Test func anEndpointRunsItsLauncher() throws {
        let launcher = try #require(
            HerdrLauncher(executablePath: "/opt/herdr/launch", socketPath: "/tmp/h/herdr.sock"))
        #expect(
            HeelerSSHTransport.heelerPluginCommand(
                arguments: ["plugin", "uninstall", "herdr-mobile.pairing"], session: "work",
                launcher: launcher, findsNode: false)
                == #"/bin/sh -c 'export HERDR_SOCKET_PATH="$2"; exec "$1" plugin uninstall herdr-mobile.pairing' herdr '/opt/herdr/launch' '/tmp/h/herdr.sock'"#)
        #expect(
            HeelerSSHTransport.heelerPluginCommand(
                arguments: ["plugin", "install"], session: "", launcher: launcher, findsNode: true)
                == #"/bin/sh -c 'export HERDR_SOCKET_PATH="$2"; "#
                + NodeToolchainProbe.script
                + #"exec "$1" plugin install' herdr '/opt/herdr/launch' '/tmp/h/herdr.sock'"#)
    }

    @Test func anInstallWithoutUsableNodeSaysWhatHeelerFound() throws {
        func failure(_ stderr: String, status: Int32 = 3) -> HeelerPluginStepError {
            HeelerPluginStepError(
                step: .install, exitStatus: status, stderr: Data(stderr.utf8), stdout: Data())
        }
        let missing = failure("mise WARN noise\n\(NodeToolchainProbe.missingMarker)\n")
        #expect(missing.nodeProblem == .missing)
        #expect(HeelerPluginActionFailure(missing).message.hasPrefix(
            "Heeler could not find Node.js 20 or newer on the Host"))
        #expect(HeelerPluginActionFailure(missing).detail?.contains("nvm") == true)
        let old = failure("\(NodeToolchainProbe.tooOldMarker)18.19.0\n")
        #expect(old.nodeProblem == .tooOld(version: "18.19.0"))
        #expect(HeelerPluginActionFailure(old).message.contains("is 18.19.0"))
        let npmless = failure("\(NodeToolchainProbe.npmMissingMarker)20.19.2\n")
        #expect(npmless.nodeProblem == .npmMissing(nodeVersion: "20.19.2"))
        #expect(HeelerPluginActionFailure(npmless).message.contains("Node.js 20.19.2 but no npm"))
        // Only the probe's own exit status counts.
        #expect(failure(NodeToolchainProbe.missingMarker, status: 1).nodeProblem == nil)
        #expect(failure("error: plugin build failed").nodeProblem == nil)
    }

    @Test func onlyAFinishedZeroExitCompletesAStep() throws {
        func check(
            _ status: Int32, reachedEOF: Bool = true, launcher: HerdrLauncher? = nil
        ) throws {
            try HeelerSSHTransport.checkHeelerPluginStep(
                .install,
                result: SSHExecResult(
                    stdout: Data(), stderr: Data("error: x".utf8), exitStatus: status,
                    reachedEOF: reachedEOF),
                bareCommand: HostSetupGuide.pluginInstallCommand, launcher: launcher)
        }
        try check(0)
        #expect(throws: HeelerPluginStepError(
            step: .install, exitStatus: 1, stderr: Data("error: x".utf8), stdout: Data())
        ) { try check(1) }
        #expect(throws: HeelerPluginStepError.self) { try check(0, reachedEOF: false) }
        #expect(throws: TransportError.herdrBinaryNotFound) { try check(127) }
        let launcher = try #require(
            HerdrLauncher(executablePath: "/opt/herdr/launch", socketPath: "/tmp/h/herdr.sock"))
        #expect(throws: TransportError.herdrLauncherNotFound(path: "/opt/herdr/launch")) {
            try check(126, launcher: launcher)
        }
    }

    /// An install from a fork would quietly move to this repository, and a
    /// GitHub install that does not name its repository may be one.
    @Test func onlyThisRepositorysInstallIsReplaced() throws {
        func action(
            _ repository: String?, version: String = "0.5.0", isEnabled: Bool = true
        ) -> HeelerPluginPresentation.Notice.Action? {
            self.action(HeelerPluginInstallation(
                version: version, isEnabled: isEnabled, repository: repository))
        }
        #expect(action("someone/Heeler") == nil)
        #expect(action("zingerlittlebee/heeler")?.steps == [.install])
        #expect(action(nil) == nil)
        // Turning a fork's plugin on replaces nothing; updating it first would.
        #expect(action("someone/Heeler", version: "0.6.0", isEnabled: false)?.steps
            == [.enable(pluginID: "heeler")])
        #expect(action("someone/Heeler", isEnabled: false) == nil)
        let json = #"{"plugins":[{"plugin_id":"heeler","version":"0.5.0","enabled":true,"source":{"kind":"github","owner":"someone","repo":"Heeler","subdir":"plugin"}}]}"#
        let decoded = try JSONDecoder().decode(PluginListResult.self, from: Data(json.utf8))
        #expect(HeelerPluginInstallation(decoded)?.repository == "someone/Heeler")
        let unnamed = #"{"plugins":[{"plugin_id":"heeler","version":"0.5.0","enabled":true,"source":{"kind":"github"}}]}"#
        let decodedUnnamed = try JSONDecoder().decode(PluginListResult.self, from: Data(unnamed.utf8))
        let installation = try #require(HeelerPluginInstallation(decodedUnnamed))
        #expect(installation.repository == nil)
        #expect(self.action(installation) == nil)
    }

    /// The plugin branch's version, as `scripts/publish-plugin.sh` reads it.
    @Test func theBranchManifestNamesItsTopLevelVersion() {
        let manifest = """
            id = "heeler"
            version = "0.6.2" # bumped by hand
            min_herdr_version = "0.7.5"

            [[build]]
            version = "9.9.9"
            """
        #expect(HeelerSSHTransport.manifestVersion(manifest) == PluginVersion(0, 6, 2))
        #expect(HeelerSSHTransport.manifestVersion("version=\"1.2.3\"\r\n") == PluginVersion(1, 2, 3))
        #expect(HeelerSSHTransport.manifestVersion("[[build]]\nversion = \"9.9.9\"") == nil)
        #expect(HeelerSSHTransport.manifestVersion("versions = \"1.0.0\"") == nil)
        #expect(HeelerSSHTransport.manifestVersion("version = 1.0.0") == nil)
        #expect(HeelerSSHTransport.manifestVersion("") == nil)
    }

    /// The read fetches the branch herdr installs, with git that cannot
    /// prompt, and leaves no scratch repository behind.
    @Test func theBranchReadFetchesThePluginBranch() {
        let command = HeelerSSHTransport.pluginBranchManifestCommand
        #expect(command.hasPrefix("/bin/sh -c '"))
        #expect(command.contains("export GIT_TERMINAL_PROMPT=0"))
        #expect(command.contains(
            "fetch -q --depth 1 https://github.com/ZingerLittleBee/Heeler.git plugin"))
        #expect(command.contains("-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30"))
        #expect(command.contains("git show FETCH_HEAD:herdr-plugin.toml"))
        #expect(command.contains("rm -rf \"$__h_d\""))
        // One quoted word: no single quote inside the body.
        #expect(command.dropFirst("/bin/sh -c '".count).dropLast().contains("'") == false)
    }

    /// herdr 0.9.5's stderr when the build cannot start `npm`, after a
    /// warning the Host's shell setup printed.
    private static let buildFailure = """
        mise WARN /home/u/.config/mise/config.toml is not trusted
        Plugin install preview:
          id: heeler
          version: 0.6.2
          build commands: 1
            build: npm ci
          replaces: heeler from github:ZingerLittleBee/Heeler@plugin
        error: plugin build failed
          plugin: heeler
          build: 1/1
          command: npm ci
          error: failed to start: No such file or directory (os error 2)


        Plugin was not installed.
        """

    @Test func aStepFailureKeepsHerdrsWordsWithoutThePreview() {
        let error = HeelerPluginStepError(
            step: .install, exitStatus: 1, stderr: Data(Self.buildFailure.utf8), stdout: Data())
        #expect(error.isBuildFailure)
        #expect(!error.isDownloadFailure)
        #expect(error.detail() == """
            error: plugin build failed
              plugin: heeler
              build: 1/1
              command: npm ci
              error: failed to start: No such file or directory (os error 2)
            Plugin was not installed.
            """)
        #expect(error.detail(lineLimit: 1) == "Plugin was not installed.")
        #expect(error.detail(characterLimit: 9) == "…stalled.")
        let failure = HeelerPluginActionFailure(error)
        #expect(failure.message.contains("npm ci"))
        #expect(failure.detail == error.detail())
    }

    @Test func stdoutStandsInForAnEmptyStderr() {
        let error = HeelerPluginStepError(
            step: .uninstall(pluginID: "herdr-mobile.pairing"), exitStatus: 1,
            stderr: Data("\n".utf8), stdout: Data("note\nerror: plugin not found\n".utf8))
        #expect(error.detail() == "error: plugin not found")
        // Without an error line, the end of the output is all there is.
        #expect(HeelerPluginStepError(
            step: .install, exitStatus: 101, stderr: Data("a\nb\n".utf8), stdout: Data()
        ).detail() == "a\nb")
        #expect(HeelerPluginActionFailure(error).message
            == "herdr could not remove the old copy of the plugin.")
    }

    @Test func failuresNameTheirCause() {
        func message(_ stderr: String) -> String {
            HeelerPluginActionFailure(
                HeelerPluginStepError(
                    step: .install, exitStatus: 1, stderr: Data(stderr.utf8), stdout: Data())
            ).message
        }
        #expect(message("error: git failed with status exit status: 128: fatal: unable to access")
            .contains("github.com"))
        #expect(message(
            "error: client protocol 22 is newer than server protocol 21; restart the Herdr server "
                + "before using this command.").contains("Restart the herdr server"))
        #expect(message("error: something else") == "herdr could not install the plugin.")
        #expect(HeelerPluginActionFailure(TransportError.timedOut).message.contains("may still complete"))
        #expect(HeelerPluginActionFailure(HerdrAPIError(code: "plugin_not_found", message: "x"))
            == HeelerPluginActionFailure(
                message: "herdr could not turn the plugin on.", detail: "plugin_not_found: x"))
    }
}

@MainActor
@Suite("Heeler plugin status reads", .timeLimit(.minutes(1)))
struct HeelerPluginStatusReadTests {
    private let hostID = UUID()

    @Test func mapsTransportAnswersToStatuses() async {
        let transport = ScriptedTransport()
        #expect(await HeelerPluginStatus.read(over: transport) == .notInstalled)
        let installation = HeelerPluginInstallation(version: "0.6.0")
        await transport.setHeelerPlugin(.success(installation))
        #expect(await HeelerPluginStatus.read(over: transport) == .installed(installation))
        await transport.setHeelerPlugin(
            .failure(TransportError.hostFeatureUnavailable(feature: "The Heeler plugin")))
        #expect(await HeelerPluginStatus.read(over: transport) == .unsupportedPlatform)
        // A refusal or a garbled answer says nothing about the plugin.
        for failure: any Error in [
            HerdrAPIError(code: "plugin_registry_load_failed", message: "x"),
            TransportError.malformedResponse("x"), TransportError.timedOut,
        ] {
            await transport.setHeelerPlugin(.failure(failure))
            #expect(await HeelerPluginStatus.read(over: transport) == .unavailable)
        }
    }

    @Test func storeReadsOnDemandAndAnUnconnectedHostIsUnavailable() async {
        let transport = ScriptedTransport()
        let installation = HeelerPluginInstallation(version: "0.5.0")
        await transport.setHeelerPlugin(.success(installation))
        let offlineID = UUID()
        let provider = ScriptedTransportProvider(transports: [hostID: transport])
        let store = HeelerPluginStatusStore()
        #expect(store.status(for: hostID) == nil)
        await store.refresh([hostID, offlineID], transports: provider)
        #expect(store.status(for: hostID) == .installed(installation))
        #expect(store.status(for: offlineID) == .unavailable)
        #expect(await transport.heelerPluginReads == 1)
        store.invalidate(hostID)
        #expect(store.status(for: hostID) == nil)
    }

    @Test func aRefreshKeepsTheLastStatusUntilItsReadLands() async {
        let transport = ScriptedTransport()
        let old = HeelerPluginInstallation(version: "0.5.0")
        await transport.setHeelerPlugin(.success(old))
        let provider = ScriptedTransportProvider(transports: [hostID: transport])
        let store = HeelerPluginStatusStore()
        await store.refresh([hostID], transports: provider)

        let updated = HeelerPluginInstallation(version: "0.6.0")
        await transport.setHeelerPlugin(.success(updated))
        let gate = ScriptedTransportCallGate()
        await transport.gateNextHeelerPluginRead(gate)
        let refresh = Task { await store.refresh([hostID], transports: provider) }
        await gate.waitForEntry()
        #expect(store.status(for: hostID) == .installed(old))
        await gate.open()
        await refresh.value
        #expect(store.status(for: hostID) == .installed(updated))
    }

    @Test func anInvalidationDropsAnInFlightRead() async {
        let transport = ScriptedTransport()
        await transport.setHeelerPlugin(.success(HeelerPluginInstallation(version: "0.5.0")))
        let provider = ScriptedTransportProvider(transports: [hostID: transport])
        let store = HeelerPluginStatusStore()
        let gate = ScriptedTransportCallGate()
        await transport.gateNextHeelerPluginRead(gate)
        let refresh = Task { await store.refresh([hostID], transports: provider) }
        await gate.waitForEntry()
        #expect(store.status(for: hostID) == .checking)
        store.invalidate(hostID)
        await gate.open()
        await refresh.value
        #expect(store.status(for: hostID) == nil)
    }

    /// A screen that leaves mid-read must not turn a known version into
    /// "unknown" for every other screen.
    @Test func aCancelledRefreshKeepsTheLastStatus() async {
        let transport = ScriptedTransport()
        let old = HeelerPluginInstallation(version: "0.5.0")
        await transport.setHeelerPlugin(.success(old))
        let provider = ScriptedTransportProvider(transports: [hostID: transport])
        let store = HeelerPluginStatusStore()
        await store.refresh([hostID], transports: provider)

        await transport.setHeelerPlugin(.failure(CancellationError()))
        let gate = ScriptedTransportCallGate()
        await transport.gateNextHeelerPluginRead(gate)
        let refresh = Task { await store.refresh([hostID], transports: provider) }
        await gate.waitForEntry()
        refresh.cancel()
        await gate.open()
        await refresh.value
        #expect(store.status(for: hostID) == .installed(old))
    }

    @Test func aCancelledFirstRefreshLeavesNoStatus() async {
        let transport = ScriptedTransport()
        let provider = ScriptedTransportProvider(transports: [hostID: transport])
        let store = HeelerPluginStatusStore()
        let gate = ScriptedTransportCallGate()
        await transport.gateNextHeelerPluginRead(gate)
        let refresh = Task { await store.refresh([hostID], transports: provider) }
        await gate.waitForEntry()
        refresh.cancel()
        await gate.open()
        await refresh.value
        #expect(store.status(for: hostID) == nil)
    }
}
