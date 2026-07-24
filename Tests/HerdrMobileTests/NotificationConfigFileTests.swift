import Foundation
import Testing

@testable import HerdrMobile

@Suite("Notification config file (notify.json)")
struct NotificationConfigFileTests {
    @Test func decodesAnAbsentOrCorruptFileAsEmpty() throws {
        #expect(try NotificationConfigFile.decode(nil).relayURL == nil)
        #expect(try NotificationConfigFile.decode(Data("not json".utf8)).relayURL == nil)
        // A JSON array is valid JSON but not a settings object; treat as empty.
        #expect(try NotificationConfigFile.decode(Data("[]".utf8)).relayURL == nil)
    }

    @Test func readsAnExistingRelayURLTrailingSlashTrimmed() throws {
        let config = try NotificationConfigFile.decode(
            Data(#"{"relay_url":"https://relay.example.com/"}"#.utf8))
        #expect(config.relayURL == "https://relay.example.com")
    }

    @Test func settingRelayURLPreservesEveryOtherField() throws {
        let existing = try NotificationConfigFile.decode(
            Data(#"{"debounce_ms":2000,"retry_delay_ms":500,"future_knob":"kept"}"#.utf8))

        let updated = existing.settingRelayURL("https://relay.example.com")

        let object = try #require(
            try JSONSerialization.jsonObject(with: updated.encoded()) as? [String: Any])
        #expect(object["relay_url"] as? String == "https://relay.example.com")
        // The plugin's own knobs and any field this app does not understand
        // survive the read-merge-write untouched.
        #expect(object["debounce_ms"] as? Int == 2000)
        #expect(object["retry_delay_ms"] as? Int == 500)
        #expect(object["future_knob"] as? String == "kept")
    }

    @Test func settingRelayURLTrimsTheTrailingSlashItWrites() throws {
        let updated = NotificationConfigFile().settingRelayURL("https://relay.example.com/")
        #expect(updated.relayURL == "https://relay.example.com")
    }

    @Test func settingTheSameNormalizedURLIsEqualToTheDecodedFile() throws {
        // Drives the ceremony's "only rewrite when it changes" guard: a file
        // already holding the URL (even with a trailing slash) must compare
        // equal to the merge result so no needless write happens.
        let existing = try NotificationConfigFile.decode(
            Data(#"{"relay_url":"https://relay.example.com","debounce_ms":100}"#.utf8))
        let updated = existing.settingRelayURL("https://relay.example.com")
        #expect(updated == existing)
    }
}
