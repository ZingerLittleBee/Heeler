import Foundation
import Testing

@testable import Heeler

/// Hosts and Transport copy that localization rebuilt as whole sentences
/// still reads as before in English, and the tokens code matches on stay
/// plain.
@Suite("Hosts and Transport localization")
struct HostsTransportLocalizationTests {
    // MARK: Plain tokens

    /// `HerdrCoreSSHTransport` catches the closed link by this exact detail,
    /// so it must not depend on the locale; it is localized where it is shown.
    @Test func theClosedLinkDetailIsAPlainTokenLocalizedOnlyWhenShown() {
        #expect(HerdrCoreLink.closedDetail == "The herdr-core link closed.")
        let presentation = TransportError.channelFailed(detail: HerdrCoreLink.closedDetail).presentation
        #expect(presentation.detail == "The herdr-core link closed.")
        #expect(TransportError.displayedChannelDetail("connection reset") == "connection reset")
    }

    // MARK: Whole sentences

    @Test func aRouteLabelNamesEachWayItIsReached() {
        let jump = SSHJumpSettings(
            host: "vps.example", port: 2022, username: "dev", credentials: .password("x"))
        let overlay = OverlayRoute(networkName: "Home") { _, _, _ in
            throw TransportError.timedOut
        }

        #expect(SSHRoute(host: "10.0.0.5", port: 22).label == "10.0.0.5")
        #expect(SSHRoute(host: "100.64.0.5", port: 22, overlay: overlay).label == "100.64.0.5 over Home")
        #expect(
            SSHRoute(host: "127.0.0.1", port: 2222, jump: jump, overlay: overlay).label
                == "127.0.0.1:2222 via vps.example:2022 over Home")
    }

    /// A feature name that already ends its sentence, in either script,
    /// gets no second period.
    @Test func anUnavailableFeatureHintEndsItsSentenceOnce() {
        func hint(_ feature: String) -> PreflightCheckStatus {
            PreflightReport.failure(
                .hostFeatureUnavailable(feature: feature), authMethod: .deviceKey
            )[.remoteEnvironment]
        }

        #expect(hint("Chat needs SFTP on the Host") == .failed(hint: "Chat needs SFTP on the Host."))
        #expect(hint("Chat needs SFTP.") == .failed(hint: "Chat needs SFTP."))
        #expect(hint("チャットには SFTP が必要です。") == .failed(hint: "チャットには SFTP が必要です。"))
    }

    @Test func spokenLatencyAgreesInNumber() {
        #expect(HostLatencyFormatting.spoken(.microseconds(400)) == "Less than 1 millisecond")
        #expect(HostLatencyFormatting.spoken(.milliseconds(1)) == "1 millisecond")
        #expect(HostLatencyFormatting.spoken(.milliseconds(12)) == "12 milliseconds")
        #expect(HostLatencyFormatting.formatted(.milliseconds(12)) == "12 ms")
    }

    @Test func aRefusedLingerNamesTheReasonOnlyWhenThereIsOne() {
        #expect(
            HostHelperError.lingerRefused(user: "me", detail: "").message
                == "This Host did not let Heeler turn on linger. "
                + "An administrator can run: sudo loginctl enable-linger me")
        #expect(
            HostHelperError.lingerRefused(user: "me", detail: "Access denied").message
                == "This Host did not let Heeler turn on linger: Access denied "
                + "An administrator can run: sudo loginctl enable-linger me")
    }

    @Test func aMissingNodeSaysWhatTheHostHas() {
        let minimum = NodeToolchainProbe.minimumMajorVersion
        #expect(
            HostHelperPresentation(.nodeMissing(tooOld: "18.19.0")).detail
                == "The Host Helper needs Node.js \(minimum) or newer, and this Host has 18.19.0.")
        #expect(
            HostHelperPresentation(.nodeMissing(tooOld: nil)).detail
                == "The Host Helper needs Node.js \(minimum) or newer, "
                + "and Heeler could not find it on this Host.")
        #expect(
            HostHelperPresentation(.unsupportedPlatform(.other("FreeBSD"))).detail
                == "The Host Helper does not run on FreeBSD.")
    }

    @Test func removingUnreachableHostsWarnsInWholeSentences() {
        let request = HostRemovalRequest(
            hosts: [
                Host(name: "Studio", address: "studio.local", username: "dev"),
                Host(name: "Pi", address: "pi.local", username: "pi"),
            ],
            deletesNotificationKey: true,
            leavesNotificationsBehind: true)

        #expect(
            request.message
                == "This permanently deletes the Host configuration, its trusted host key, any "
                + "saved password, and the Notification Key from the Keychain. Heeler can't "
                + "reach some of these Hosts, so they may keep sending notifications to this "
                + "device. Connect to them first to stop those notifications. This cannot be undone.")
    }

    @Test func aCoreSocketReadsAsRunningOnlyForAWindowsPipe() {
        #expect(
            ServerKindDetection.CoreFinding.socketFilePresent(
                version: "0.2.0", socketPath: #"\\.\pipe\herdr-core"#
            ).summary == "0.2.0, running")
        #expect(
            ServerKindDetection.CoreFinding.socketFilePresent(
                version: "0.2.0", socketPath: "/tmp/herdr-core/core.sock"
            ).summary == "0.2.0, socket found")
    }

    @Test func aLeftoverPluginCopyAsksForTheRightSteps() throws {
        func message(_ installation: HeelerPluginInstallation) throws -> String {
            try #require(
                HeelerPluginPresentation(
                    .installed(installation), session: "", bundled: PluginVersion(0, 6, 0)
                ).notice
            ).message
        }

        #expect(
            try message(HeelerPluginInstallation(version: "0.6.0", leftoverLegacyIDs: ["herdr-mobile.pairing"]))
                == "An old copy of the Heeler plugin is still installed under its former name "
                + "and may send duplicate notifications. Remove it:")
        #expect(
            try message(HeelerPluginInstallation(version: "0.5.0", leftoverLegacyIDs: ["herdr-mobile.pairing"]))
                == "An old copy of the Heeler plugin is still installed under its former name "
                + "and may send duplicate notifications. Remove it and update the plugin:")
        #expect(
            try message(HeelerPluginInstallation(version: "0.6.0", hasManifestWarning: true))
                == "herdr could not read the plugin's manifest, so its version may be out of "
                + "date. Reinstall it.")
        #expect(
            try message(HeelerPluginInstallation(version: "0.6.0", source: .local, hasManifestWarning: true))
                == "herdr could not read the plugin's manifest, so its version may be out of "
                + "date. Check the linked checkout.")
    }
}
