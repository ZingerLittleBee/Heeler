import Foundation
import Testing

@testable import HerdrMobile

@MainActor
@Suite("Notification relay settings")
struct NotificationRelaySettingsTests {
    /// A throwaway defaults domain per test, so persistence is real but isolated.
    private func makeDefaults() -> UserDefaults {
        let name = "relay-settings-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func emptyByDefaultMeansNoCustomURL() {
        let settings = NotificationRelaySettings(defaults: makeDefaults())
        #expect(settings.rawValue.isEmpty)
        #expect(settings.relayURL == nil)
        #expect(!settings.hasInvalidEntry)
        #expect(
            NotificationRelayEndpoint.productionBaseURL?.absoluteString
                == "https://heeler-apns.bybee.dev")
    }

    @Test func acceptsAnHTTPSBaseURL() {
        let settings = NotificationRelaySettings(defaults: makeDefaults())
        settings.rawValue = "https://relay.example.com"
        #expect(settings.relayURL?.absoluteString == "https://relay.example.com")
        #expect(!settings.hasInvalidEntry)
    }

    @Test func acceptsAPathPrefixAndTrimsSurroundingWhitespace() {
        let settings = NotificationRelaySettings(defaults: makeDefaults())
        settings.rawValue = "  https://example.com/herdr-relay  "
        #expect(settings.relayURL?.absoluteString == "https://example.com/herdr-relay")
    }

    @Test func rejectsMalformedOrNonHTTPURLs() {
        #expect(NotificationRelaySettings.validate("relay.example.com") == nil)
        #expect(NotificationRelaySettings.validate("ftp://relay.example.com") == nil)
        #expect(NotificationRelaySettings.validate("https://") == nil)
        #expect(NotificationRelaySettings.validate("https://relay.example.com?x=1") == nil)
        #expect(NotificationRelaySettings.validate("not a url at all") == nil)
    }

    @Test func flagsANonEmptyButInvalidEntry() {
        let settings = NotificationRelaySettings(defaults: makeDefaults())
        settings.rawValue = "relay.example.com"
        #expect(settings.relayURL == nil)
        #expect(settings.hasInvalidEntry)
    }

    @Test func persistsAndReloadsTheRawValue() {
        let defaults = makeDefaults()
        let first = NotificationRelaySettings(defaults: defaults)
        first.rawValue = "https://relay.example.com"

        let second = NotificationRelaySettings(defaults: defaults)
        #expect(second.rawValue == "https://relay.example.com")
    }

    @Test func clearingTheFieldRemovesThePersistedValue() {
        let defaults = makeDefaults()
        let first = NotificationRelaySettings(defaults: defaults)
        first.rawValue = "https://relay.example.com"
        first.rawValue = ""

        let second = NotificationRelaySettings(defaults: defaults)
        #expect(second.rawValue.isEmpty)
        #expect(second.relayURL == nil)
    }

    @Test func migratesThePreviousProductionRelayToTheCurrentDefault() {
        let defaults = makeDefaults()
        defaults.set(
            "https://herdr-push-relay.69709991236.workers.dev/",
            forKey: "notification-relay-url")

        let settings = NotificationRelaySettings(defaults: defaults)

        #expect(settings.rawValue.isEmpty)
        #expect(settings.relayURL == nil)
        #expect(defaults.string(forKey: "notification-relay-url") == nil)
        #expect(
            NotificationRelayEndpoint.resolve(customBaseURL: settings.relayURL)?
                .absoluteString == "https://heeler-apns.bybee.dev")
    }
}
