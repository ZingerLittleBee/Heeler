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
}
