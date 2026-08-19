import Foundation
import Testing

@testable import Heeler

@Suite("Notification registration file v1")
struct NotificationRegistrationFileTests {
    private let key = Data(0..<32)
    private var entry: NotificationDeviceEntry {
        NotificationDeviceEntry(
            token: APNSDeviceToken(hex: "a1b2c3", environment: .production),
            key: key,
            notify: NotificationTriggerPreferences(blocked: true, done: false))
    }

    @Test func absentFileDecodesAsEmpty() throws {
        let file = try NotificationRegistrationFile.decode(nil)

        #expect(file.devices.isEmpty)
    }

    @Test(arguments: [
        "not json at all",
        "[1,2,3]",
        #"{"devices":[]}"#,
        #"{"v":"1","devices":[]}"#,
    ])
    func corruptFileDecodesAsEmptySoRegistrationSelfHeals(text: String) throws {
        let file = try NotificationRegistrationFile.decode(Data(text.utf8))

        #expect(file.devices.isEmpty)
    }

    @Test func aDifferentVersionIsRefusedNotClobbered() {
        let data = Data(#"{"v":2,"devices":[{"token":"zz"}]}"#.utf8)

        #expect(throws: NotificationRegistrationError.unsupportedFileVersion(2)) {
            _ = try NotificationRegistrationFile.decode(data)
        }
    }

    @Test func upsertedEntryEncodesTheContractShape() throws {
        let data = try NotificationRegistrationFile().upserting(entry).encoded()

        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["v"] as? Int == 1)
        let devices = try #require(object["devices"] as? [[String: Any]])
        #expect(devices.count == 1)
        let device = try #require(devices.first)
        #expect(device["token"] as? String == "a1b2c3")
        #expect(device["key"] as? String == key.base64URLEncodedString())
        #expect(device["env"] as? String == "production")
        let notify = try #require(device["notify"] as? [String: Bool])
        #expect(notify == ["blocked": true, "done": false])
    }

    @Test func reUpsertingTheSameTokenReplacesItsEntry() throws {
        let first = NotificationRegistrationFile().upserting(entry)
        let updated = NotificationDeviceEntry(
            token: entry.token, key: key,
            notify: NotificationTriggerPreferences(blocked: false, done: true))

        let file = first.upserting(updated)

        #expect(file.devices.count == 1)
        #expect(file.devices.first?["notify"]?["blocked"] == .bool(false))
        #expect(file.devices.first?["notify"]?["done"] == .bool(true))
    }

    @Test func foreignEntriesAndTheirUnknownFieldsSurviveARewrite() throws {
        let existing = Data(
            (#"{"v":1,"devices":[{"token":"ffff","key":"kk","env":"sandbox","#
                + #""notify":{"blocked":true},"future_field":"kept"}]}"#).utf8)

        let file = try NotificationRegistrationFile.decode(existing).upserting(entry)
        let reread = try NotificationRegistrationFile.decode(try file.encoded())

        #expect(reread.devices.count == 2)
        let foreign = try #require(
            reread.devices.first { $0["token"]?.stringValue == "ffff" })
        #expect(foreign["future_field"]?.stringValue == "kept")
        #expect(foreign["notify"]?["blocked"] == .bool(true))
        #expect(reread.containsDevice(token: entry.token.hex))
    }

    @Test func removingATokenDropsOnlyItsEntry() throws {
        let other = NotificationDeviceEntry(
            token: APNSDeviceToken(hex: "dddd", environment: .sandbox),
            key: Data(repeating: 7, count: 32),
            notify: NotificationTriggerPreferences())
        let file = NotificationRegistrationFile().upserting(entry).upserting(other)

        let removed = file.removing(token: entry.token.hex)

        #expect(!removed.containsDevice(token: entry.token.hex))
        #expect(removed.containsDevice(token: "dddd"))
        #expect(removed.devices.count == 1)
    }

    @Test func removingAnUnknownTokenChangesNothing() {
        let file = NotificationRegistrationFile().upserting(entry)

        #expect(file.removing(token: "not-there") == file)
    }

    @Test func preferencesReadTheEntrysNotifyFlags() {
        let file = NotificationRegistrationFile().upserting(entry)

        #expect(
            file.preferences(token: entry.token.hex)
                == NotificationTriggerPreferences(blocked: true, done: false))
        #expect(file.preferences(token: "not-there") == nil)
    }

    @Test func missingOrMistypedNotifyFlagsReadAsOff() throws {
        // Fail closed, exactly like the plugin's reader (v1 contract).
        let file = try NotificationRegistrationFile.decode(
            Data(
                (#"{"v":1,"devices":[{"token":"ffff","key":"kk","env":"sandbox","#
                    + #""notify":{"blocked":"yes"}}]}"#).utf8))

        #expect(
            file.preferences(token: "ffff")
                == NotificationTriggerPreferences(blocked: false, done: false))
    }

    @Test func settingLiveActivityWritesTheContractShapeAndClearsIt() throws {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let file = NotificationRegistrationFile().upserting(entry)
            .settingLiveActivity(
                token: "deadbeef", startedAt: started, forDeviceToken: entry.token.hex)

        let live = try #require(file.liveActivity(forDeviceToken: entry.token.hex))
        #expect(live.token == "deadbeef")
        #expect(live.startedAt == "2023-11-14T22:13:20Z")

        let object = try #require(
            try JSONSerialization.jsonObject(with: try file.encoded()) as? [String: Any])
        let devices = try #require(object["devices"] as? [[String: Any]])
        let device = try #require(devices.first)
        let wire = try #require(device["live_activity"] as? [String: Any])
        #expect(wire["token"] as? String == "deadbeef")
        #expect(wire["started_at"] as? String == "2023-11-14T22:13:20Z")
        #expect(wire["pinned_pane_ids"] as? [String] == [])
        #expect(live.pinnedPaneIDs.isEmpty)

        let cleared = file.clearingLiveActivity(forDeviceToken: entry.token.hex)
        #expect(cleared.liveActivity(forDeviceToken: entry.token.hex) == nil)
        #expect(cleared.containsDevice(token: entry.token.hex))
        let clearedDevice = try #require(
            try JSONSerialization.jsonObject(with: try cleared.encoded()) as? [String: Any])
        let clearedEntry = try #require(
            (clearedDevice["devices"] as? [[String: Any]])?.first)
        #expect(clearedEntry["live_activity"] == nil)
        #expect(clearedEntry["token"] as? String == entry.token.hex)
    }

    @Test func settingLiveActivityPreservesUnknownFieldsOnTheDeviceEntry() throws {
        let existing = Data(
            (#"{"v":1,"devices":[{"token":"a1b2c3","key":"kk","env":"production","#
                + #""notify":{"blocked":true,"done":true},"future_field":"kept","#
                + #""other":{"nested":true}}]}"#).utf8)
        let started = Date(timeIntervalSince1970: 1_700_000_000)

        let file = try NotificationRegistrationFile.decode(existing)
            .settingLiveActivity(
                token: "aabbcc", startedAt: started, forDeviceToken: "a1b2c3")
        let device = try #require(file.devices.first)
        #expect(device["future_field"]?.stringValue == "kept")
        #expect(device["other"]?["nested"] == .bool(true))
        #expect(device["key"]?.stringValue == "kk")
        #expect(file.liveActivity(forDeviceToken: "a1b2c3")?.token == "aabbcc")
        #expect(file.liveActivity(forDeviceToken: "a1b2c3")?.pinnedPaneIDs == [])

        let cleared = file.clearingLiveActivity(forDeviceToken: "a1b2c3")
        let afterClear = try #require(cleared.devices.first)
        #expect(afterClear["future_field"]?.stringValue == "kept")
        #expect(afterClear["other"]?["nested"] == .bool(true))
        #expect(cleared.liveActivity(forDeviceToken: "a1b2c3") == nil)
    }

    @Test func upsertingMergesKeysSoALiveActivityTokenSurvivesReregistration() throws {
        let existing = Data(
            (#"{"v":1,"devices":[{"token":"a1b2c3","key":"old-key","env":"production","#
                + #""notify":{"blocked":true,"done":true},"future_field":"kept","#
                + #""live_activity":{"token":"la","started_at":"2024-01-01T00:00:00Z"}}]}"#)
                .utf8)

        let file = try NotificationRegistrationFile.decode(existing).upserting(entry)

        #expect(file.devices.count == 1)
        let device = try #require(file.devices.first)
        #expect(device["live_activity"]?["token"]?.stringValue == "la")
        #expect(device["live_activity"]?["started_at"]?.stringValue == "2024-01-01T00:00:00Z")
        #expect(device["future_field"]?.stringValue == "kept")
        #expect(device["key"]?.stringValue == key.base64URLEncodedString())
        #expect(device["notify"]?["blocked"] == .bool(true))
        #expect(device["notify"]?["done"] == .bool(false))
    }

    @Test func settingLiveActivityWritesPinnedPaneIDsMostRecentFirst() throws {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let file = NotificationRegistrationFile().upserting(entry)
            .settingLiveActivity(
                token: "deadbeef", startedAt: started, forDeviceToken: entry.token.hex,
                pinnedPaneIDs: ["w1:p2", "w1:p1"])

        let live = try #require(file.liveActivity(forDeviceToken: entry.token.hex))
        #expect(live.pinnedPaneIDs == ["w1:p2", "w1:p1"])

        let reread = try NotificationRegistrationFile.decode(try file.encoded())
        #expect(
            reread.liveActivity(forDeviceToken: entry.token.hex)?.pinnedPaneIDs
                == ["w1:p2", "w1:p1"])

        let object = try #require(
            try JSONSerialization.jsonObject(with: try file.encoded()) as? [String: Any])
        let device = try #require((object["devices"] as? [[String: Any]])?.first)
        let wire = try #require(device["live_activity"] as? [String: Any])
        #expect(wire["pinned_pane_ids"] as? [String] == ["w1:p2", "w1:p1"])
    }

    @Test func settingPinnedPaneIDsMergesWithoutDroppingTokenOrUnknownFields() throws {
        let existing = Data(
            (#"{"v":1,"devices":[{"token":"a1b2c3","key":"kk","env":"production","#
                + #""notify":{"blocked":true,"done":true},"future_field":"kept","#
                + #""live_activity":{"token":"la","started_at":"2024-01-01T00:00:00Z","#
                + #""future_la":"kept"}}]}"#).utf8)

        let file = try NotificationRegistrationFile.decode(existing)
            .settingLiveActivityPinnedPaneIDs(["w1:p9", "w1:p1"], forDeviceToken: "a1b2c3")
        let device = try #require(file.devices.first)
        #expect(device["future_field"]?.stringValue == "kept")
        #expect(device["live_activity"]?["token"]?.stringValue == "la")
        #expect(device["live_activity"]?["started_at"]?.stringValue == "2024-01-01T00:00:00Z")
        #expect(device["live_activity"]?["future_la"]?.stringValue == "kept")
        #expect(file.liveActivity(forDeviceToken: "a1b2c3")?.pinnedPaneIDs == ["w1:p9", "w1:p1"])

        let rewritten = file.settingLiveActivity(
            token: "aabbcc",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            forDeviceToken: "a1b2c3",
            pinnedPaneIDs: ["w1:p1"])
        let after = try #require(rewritten.devices.first)
        #expect(after["future_field"]?.stringValue == "kept")
        #expect(after["live_activity"]?["future_la"]?.stringValue == "kept")
        #expect(after["live_activity"]?["token"]?.stringValue == "aabbcc")
        #expect(rewritten.liveActivity(forDeviceToken: "a1b2c3")?.pinnedPaneIDs == ["w1:p1"])
    }

    @Test func settingPinnedPaneIDsIsANoOpWithoutLiveActivity() throws {
        let file = NotificationRegistrationFile().upserting(entry)
        #expect(file.settingLiveActivityPinnedPaneIDs(["w1:p1"], forDeviceToken: entry.token.hex) == file)
        #expect(file.settingLiveActivityPinnedPaneIDs(["w1:p1"], forDeviceToken: "missing") == file)
    }

    @Test(arguments: [
        #"{"v":1,"devices":[{"token":"ffff","live_activity":{"token":"la","started_at":"t"}}]}"#,
        #"{"v":1,"devices":[{"token":"ffff","live_activity":{"token":"la","started_at":"t","pinned_pane_ids":null}}]}"#,
        #"{"v":1,"devices":[{"token":"ffff","live_activity":{"token":"la","started_at":"t","pinned_pane_ids":"w1:p1"}}]}"#,
        #"{"v":1,"devices":[{"token":"ffff","live_activity":{"token":"la","started_at":"t","pinned_pane_ids":["w1:p1",1]}}]}"#,
        #"{"v":1,"devices":[{"token":"ffff","live_activity":{"token":"la","started_at":"t","pinned_pane_ids":{"pane":"w1:p1"}}}]}"#,
    ])
    func malformedPinnedPaneIDsReadAsEmpty(text: String) throws {
        let file = try NotificationRegistrationFile.decode(Data(text.utf8))
        #expect(file.liveActivity(forDeviceToken: "ffff")?.pinnedPaneIDs == [])
        #expect(
            NotificationRegistrationFile.pinnedPaneIDs(
                from: file.devices.first?["live_activity"]?["pinned_pane_ids"])
                == [])
    }
}
