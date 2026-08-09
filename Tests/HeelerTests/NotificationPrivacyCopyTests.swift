import Foundation
import Testing

@testable import Heeler

/// The disclosure copy is a cross-surface contract (ADR 0008, #76): the
/// explainer and the settings section render the same strings, and the ticket
/// pins the load-bearing claims. These assertions guard those claims so a
/// well-meaning copy edit cannot quietly drop one.
@Suite("Notification privacy copy")
struct NotificationPrivacyCopyTests {
    private var allProse: String {
        (
            [
                NotificationPrivacyCopy.summary,
                NotificationPrivacyCopy.relaySeesTitle,
                NotificationPrivacyCopy.relayCannotSeeTitle,
                NotificationPrivacyCopy.customRelayCaveat,
                NotificationPrivacyCopy.explainerTitle,
            ] + NotificationPrivacyCopy.relaySees + NotificationPrivacyCopy.relayCannotSee
        ).joined(separator: "\n")
    }

    @Test func callsItAPushRelayNeverAServer() {
        #expect(allProse.localizedCaseInsensitiveContains("push relay"))
        // "never a server" (ADR 0008): the word server must not appear.
        #expect(!allProse.localizedCaseInsensitiveContains("server"))
    }

    @Test func statesWhatTheRelaySees() {
        let sees = NotificationPrivacyCopy.relaySees.joined(separator: "\n")
        #expect(sees.localizedCaseInsensitiveContains("push token"))
        #expect(sees.localizedCaseInsensitiveContains("ciphertext"))
        #expect(sees.localizedCaseInsensitiveContains("IP"))
        #expect(sees.localizedCaseInsensitiveContains("how often"))
    }

    @Test func statesWhatTheRelayCannotSee() {
        let cannot = NotificationPrivacyCopy.relayCannotSee.joined(separator: "\n")
        // The exact plaintext fields, so the claim is concrete, not hand-wavy.
        #expect(cannot.localizedCaseInsensitiveContains("project name"))
        #expect(cannot.localizedCaseInsensitiveContains("task title"))
        #expect(cannot.localizedCaseInsensitiveContains("agent type"))
        #expect(cannot.localizedCaseInsensitiveContains("status"))
        #expect(cannot.localizedCaseInsensitiveContains("pane ID"))
        #expect(cannot.localizedCaseInsensitiveContains("timestamp"))
        #expect(cannot.localizedCaseInsensitiveContains("Notification Key"))
    }

    @Test func statesTheSelfBuiltAppCaveat() {
        let caveat = NotificationPrivacyCopy.customRelayCaveat
        #expect(caveat.localizedCaseInsensitiveContains("build and sign yourself"))
        #expect(caveat.localizedCaseInsensitiveContains("bundle id"))
        #expect(caveat.localizedCaseInsensitiveContains("APNs credentials"))
        #expect(caveat.localizedCaseInsensitiveContains("App Store"))
    }

    @Test func linksToThePrivacyPolicy() throws {
        let url = try #require(NotificationPrivacyCopy.privacyPolicyURL)
        #expect(url.absoluteString.hasSuffix("PRIVACY.md"))
    }
}
