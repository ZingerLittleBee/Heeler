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
    }

    @Test func statesWhatTheRelayCannotSee() {
        let cannot = NotificationPrivacyCopy.relayCannotSee.joined(separator: "\n")
        // The exact plaintext fields, so the claim is concrete, not hand-wavy.
        #expect(cannot.localizedCaseInsensitiveContains("agent names"))
        #expect(cannot.localizedCaseInsensitiveContains("statuses"))
        #expect(cannot.localizedCaseInsensitiveContains("pane ids"))
    }

    @Test func statesTheSelfBuiltAppCaveat() {
        let caveat = NotificationPrivacyCopy.customRelayCaveat
        #expect(caveat.localizedCaseInsensitiveContains("build the app yourself"))
        #expect(caveat.localizedCaseInsensitiveContains("bundle id"))
    }

    @Test func linksToThePrivacyPolicy() throws {
        let url = try #require(NotificationPrivacyCopy.privacyPolicyURL)
        #expect(url.absoluteString.hasSuffix("PRIVACY.md"))
    }
}
