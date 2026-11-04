import Foundation
import Testing

@testable import Heeler

@Suite("Notification registration file v1")
struct NotificationRegistrationFileTests {
    private let key = Data(0..<32)
    private var wireKey: String { key.base64URLEncodedString() }
    private var entry: NotificationDeviceEntry {
        NotificationDeviceEntry(
            token: APNSDeviceToken(hex: "a1b2c3", environment: .production),
            key: key, session: "",
            notify: NotificationTriggerPreferences(blocked: true, done: false))
    }
    private var owner: NotificationRegistrationOwner { entry.owner }

    /// Installed plugins drop a Live Activity layout with a field they do
    /// not know, and the right side never reaches a Live Activity.
    @Test func theRightSideAndItsTotalsStayOutOfThePluginsRowLayout() throws {
        let original = try NotificationRegistrationFile().registering(entry).settingLiveActivity(
            token: "abcd", startedAt: Date(timeIntervalSince1970: 0), for: owner, pinnedPaneIDs: [])
        let layout = AgentRowLayout(
            rows: [[.init(.workspace), .init(.changes)]], trailing: [[.init(.host)], [], [.init(.changes)]])
        let updated = try original.settingLiveActivityRowLayout(layout, hostName: "Studio Mac", for: owner)
        let reloaded = try NotificationRegistrationFile.decode(updated.encoded())
        let rowLayout = try #require(reloaded.devices.first?["live_activity"]?["row_layout"])
        #expect(rowLayout["rows"] == .array([.array([.object(["token": .string("workspace")])])]))
        #expect(rowLayout["trailing"] == nil)
    }

    @Test func liveActivityLayoutUpdatesPreserveTokensPinsAndOtherDevices() throws {
        let original = try NotificationRegistrationFile().registering(entry).settingLiveActivity(
            token: "abcd", startedAt: Date(timeIntervalSince1970: 0), for: owner,
            pinnedPaneIDs: ["w1:p1"])
        let layout = AgentRowLayout(rows: [[.init(.workspace, bold: false)], [], [.init(.directory, dim: true)]])
        let updated = try original.settingLiveActivityRowLayout(
            layout, hostName: "Studio Mac", for: owner)
        let reloaded = try NotificationRegistrationFile.decode(updated.encoded())
        #expect(reloaded.liveActivity(for: owner)
            == original.liveActivity(for: owner))
        #expect(reloaded.preferences(for: owner) == entry.notify)
        let live = try #require(reloaded.devices.first?["live_activity"])
        #expect(live["host_name"] == .string("Studio Mac"))
        #expect(live["row_layout"]?["rows"] == .array([
            .array([.object(["token": .string("workspace"), "bold": .bool(false)])]), .array([]),
            .array([.object(["token": .string("directory"), "dim": .bool(true)])]),
        ]))
        let other = NotificationRegistrationOwner(
            deviceToken: entry.token.hex, key: Data(repeating: 9, count: 32), session: "")
        #expect(throws: NotificationRegistrationError.deviceNotRegistered) {
            try original.settingLiveActivityRowLayout(layout, for: other)
        }
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

    @Test func registeredEntryEncodesTheContractShape() throws {
        let data = try NotificationRegistrationFile().registering(entry).encoded()

        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["v"] as? Int == 1)
        let devices = try #require(object["devices"] as? [[String: Any]])
        #expect(devices.count == 1)
        let device = try #require(devices.first)
        #expect(device["token"] as? String == "a1b2c3")
        #expect(device["key"] as? String == key.base64URLEncodedString())
        #expect(device["env"] as? String == "production")
        #expect(device["session"] as? String == "")
        let notify = try #require(device["notify"] as? [String: Bool])
        #expect(notify == ["blocked": true, "done": false])
    }

    @Test func reRegisteringTheSameHostReplacesItsEntry() throws {
        let first = NotificationRegistrationFile().registering(entry)
        let updated = NotificationDeviceEntry(
            token: entry.token, key: key, session: "",
            notify: NotificationTriggerPreferences(blocked: false, done: true))

        let file = first.registering(updated)

        #expect(file.devices.count == 1)
        #expect(file.devices.first?["notify"]?["blocked"] == .bool(false))
        #expect(file.devices.first?["notify"]?["done"] == .bool(true))
    }

    @Test func foreignEntriesAndTheirUnknownFieldsSurviveARewrite() throws {
        let existing = Data(
            (#"{"v":1,"devices":[{"token":"ffff","key":"kk","env":"sandbox","#
                + #""notify":{"blocked":true},"future_field":"kept"}]}"#).utf8)

        let file = try NotificationRegistrationFile.decode(existing).registering(entry)
        let reread = try NotificationRegistrationFile.decode(try file.encoded())

        #expect(reread.devices.count == 2)
        let foreign = try #require(
            reread.devices.first { $0["token"]?.stringValue == "ffff" })
        #expect(foreign["future_field"]?.stringValue == "kept")
        #expect(foreign["notify"]?["blocked"] == .bool(true))
        #expect(reread.preferences(for: owner) == entry.notify)
    }

    @Test func removingAHostDropsOnlyItsEntry() throws {
        let other = NotificationDeviceEntry(
            token: APNSDeviceToken(hex: "dddd", environment: .sandbox),
            key: Data(repeating: 7, count: 32), session: "",
            notify: NotificationTriggerPreferences())
        let file = NotificationRegistrationFile().registering(entry).registering(other)

        let removed = file.removing(owner)

        #expect(removed.preferences(for: owner) == nil)
        #expect(removed.preferences(for: other.owner) != nil)
        #expect(removed.devices.count == 1)
    }

    @Test func removingAnUnregisteredHostChangesNothing() {
        let file = NotificationRegistrationFile().registering(entry)
        let stranger = NotificationRegistrationOwner(
            deviceToken: entry.token.hex, key: Data(repeating: 1, count: 32), session: "")

        #expect(file.removing(stranger) == file)
    }

    @Test func preferencesReadTheEntrysNotifyFlags() {
        let file = NotificationRegistrationFile().registering(entry)

        #expect(
            file.preferences(for: owner)
                == NotificationTriggerPreferences(blocked: true, done: false))
        #expect(
            file.preferences(
                for: NotificationRegistrationOwner(
                    deviceToken: "not-there", key: key, session: "")) == nil)
    }

    @Test func missingOrMistypedNotifyFlagsReadAsOff() throws {
        // Fail closed, exactly like the plugin's reader (v1 contract).
        let file = try NotificationRegistrationFile.decode(
            Data(
                (#"{"v":1,"devices":[{"token":"a1b2c3","key":"\#(wireKey)","env":"sandbox","#
                    + #""notify":{"blocked":"yes"}}]}"#).utf8))

        #expect(
            file.preferences(for: owner)
                == NotificationTriggerPreferences(blocked: false, done: false))
    }

    @Test func settingLiveActivityWritesTheContractShapeAndClearsIt() throws {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let file = try NotificationRegistrationFile().registering(entry)
            .settingLiveActivity(
                token: "deadbeef", startedAt: started, for: owner)

        let live = try #require(file.liveActivity(for: owner))
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

        let cleared = file.clearingLiveActivity(token: "deadbeef", for: owner)
        #expect(cleared.liveActivity(for: owner) == nil)
        #expect(cleared.preferences(for: owner) == entry.notify)
        let clearedDevice = try #require(
            try JSONSerialization.jsonObject(with: try cleared.encoded()) as? [String: Any])
        let clearedEntry = try #require(
            (clearedDevice["devices"] as? [[String: Any]])?.first)
        #expect(clearedEntry["live_activity"] == nil)
        #expect(clearedEntry["token"] as? String == entry.token.hex)
    }

    @Test func settingLiveActivityPreservesUnknownFieldsOnTheDeviceEntry() throws {
        let existing = Data(
            (#"{"v":1,"devices":[{"token":"a1b2c3","key":"\#(wireKey)","env":"production","#
                + #""notify":{"blocked":true,"done":true},"future_field":"kept","#
                + #""other":{"nested":true}}]}"#).utf8)
        let started = Date(timeIntervalSince1970: 1_700_000_000)

        let file = try NotificationRegistrationFile.decode(existing)
            .settingLiveActivity(token: "aabbcc", startedAt: started, for: owner)
        let device = try #require(file.devices.first)
        #expect(device["future_field"]?.stringValue == "kept")
        #expect(device["other"]?["nested"] == .bool(true))
        #expect(device["key"]?.stringValue == wireKey)
        #expect(file.liveActivity(for: owner)?.token == "aabbcc")
        #expect(file.liveActivity(for: owner)?.pinnedPaneIDs == [])

        let cleared = file.clearingLiveActivity(token: nil, for: owner)
        let afterClear = try #require(cleared.devices.first)
        #expect(afterClear["future_field"]?.stringValue == "kept")
        #expect(afterClear["other"]?["nested"] == .bool(true))
        #expect(cleared.liveActivity(for: owner) == nil)
    }

    @Test func registeringMergesKeysSoALiveActivityTokenSurvivesReregistration() throws {
        let existing = Data(
            (#"{"v":1,"devices":[{"token":"a1b2c3","key":"\#(wireKey)","env":"production","#
                + #""notify":{"blocked":true,"done":true},"future_field":"kept","#
                + #""live_activity":{"token":"la","started_at":"2024-01-01T00:00:00Z"}}]}"#)
                .utf8)

        let file = try NotificationRegistrationFile.decode(existing).registering(entry)

        #expect(file.devices.count == 1)
        let device = try #require(file.devices.first)
        #expect(device["live_activity"]?["token"]?.stringValue == "la")
        #expect(device["live_activity"]?["started_at"]?.stringValue == "2024-01-01T00:00:00Z")
        #expect(device["future_field"]?.stringValue == "kept")
        #expect(device["key"]?.stringValue == key.base64URLEncodedString())
        #expect(device["session"]?.stringValue == "")
        #expect(device["notify"]?["blocked"] == .bool(true))
        #expect(device["notify"]?["done"] == .bool(false))
    }

    @Test func settingLiveActivityWritesPinnedPaneIDsMostRecentFirst() throws {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let file = try NotificationRegistrationFile().registering(entry)
            .settingLiveActivity(
                token: "deadbeef", startedAt: started, for: owner,
                pinnedPaneIDs: ["w1:p2", "w1:p1"])

        let live = try #require(file.liveActivity(for: owner))
        #expect(live.pinnedPaneIDs == ["w1:p2", "w1:p1"])

        let reread = try NotificationRegistrationFile.decode(try file.encoded())
        #expect(
            reread.liveActivity(for: owner)?.pinnedPaneIDs
                == ["w1:p2", "w1:p1"])

        let object = try #require(
            try JSONSerialization.jsonObject(with: try file.encoded()) as? [String: Any])
        let device = try #require((object["devices"] as? [[String: Any]])?.first)
        let wire = try #require(device["live_activity"] as? [String: Any])
        #expect(wire["pinned_pane_ids"] as? [String] == ["w1:p2", "w1:p1"])
    }

    @Test func settingPinnedPaneIDsMergesWithoutDroppingTokenOrUnknownFields() throws {
        let existing = Data(
            (#"{"v":1,"devices":[{"token":"a1b2c3","key":"\#(wireKey)","env":"production","#
                + #""notify":{"blocked":true,"done":true},"future_field":"kept","#
                + #""live_activity":{"token":"la","started_at":"2024-01-01T00:00:00Z","#
                + #""future_la":"kept"}}]}"#).utf8)

        let file = try NotificationRegistrationFile.decode(existing)
            .settingLiveActivityPinnedPaneIDs(["w1:p9", "w1:p1"], for: owner)
        let device = try #require(file.devices.first)
        #expect(device["future_field"]?.stringValue == "kept")
        #expect(device["live_activity"]?["token"]?.stringValue == "la")
        #expect(device["live_activity"]?["started_at"]?.stringValue == "2024-01-01T00:00:00Z")
        #expect(device["live_activity"]?["future_la"]?.stringValue == "kept")
        #expect(file.liveActivity(for: owner)?.pinnedPaneIDs == ["w1:p9", "w1:p1"])

        let rewritten = try file.settingLiveActivity(
            token: "aabbcc",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            for: owner,
            pinnedPaneIDs: ["w1:p1"])
        let after = try #require(rewritten.devices.first)
        #expect(after["future_field"]?.stringValue == "kept")
        #expect(after["live_activity"]?["future_la"]?.stringValue == "kept")
        #expect(after["live_activity"]?["token"]?.stringValue == "aabbcc")
        #expect(rewritten.liveActivity(for: owner)?.pinnedPaneIDs == ["w1:p1"])
    }

    @Test func settingPinnedPaneIDsIsANoOpWithoutLiveActivityAndRefusesAnUnregisteredHost() throws {
        let file = NotificationRegistrationFile().registering(entry)
        #expect(try file.settingLiveActivityPinnedPaneIDs(["w1:p1"], for: owner) == file)
        let missing = NotificationRegistrationOwner(
            deviceToken: "missing", key: key, session: "")
        #expect(throws: NotificationRegistrationError.deviceNotRegistered) {
            try file.settingLiveActivityPinnedPaneIDs(["w1:p1"], for: missing)
        }
    }

    @Test(arguments: [
        #"{"v":1,"devices":[{"token":"ffff","key":"AAAA","live_activity":{"token":"la","started_at":"t"}}]}"#,
        #"{"v":1,"devices":[{"token":"ffff","key":"AAAA","live_activity":{"token":"la","started_at":"t","pinned_pane_ids":null}}]}"#,
        #"{"v":1,"devices":[{"token":"ffff","key":"AAAA","live_activity":{"token":"la","started_at":"t","pinned_pane_ids":"w1:p1"}}]}"#,
        #"{"v":1,"devices":[{"token":"ffff","key":"AAAA","live_activity":{"token":"la","started_at":"t","pinned_pane_ids":["w1:p1",1]}}]}"#,
        #"{"v":1,"devices":[{"token":"ffff","key":"AAAA","live_activity":{"token":"la","started_at":"t","pinned_pane_ids":{"pane":"w1:p1"}}}]}"#,
    ])
    func malformedPinnedPaneIDsReadAsEmpty(text: String) throws {
        let file = try NotificationRegistrationFile.decode(Data(text.utf8))
        let owner = NotificationRegistrationOwner(
            deviceToken: "ffff", key: Data(count: 3), session: nil)
        #expect(file.liveActivity(for: owner)?.pinnedPaneIDs == [])
        #expect(
            NotificationRegistrationFile.pinnedPaneIDs(
                from: file.devices.first?["live_activity"]?["pinned_pane_ids"])
                == [])
    }

    // MARK: Host key and session scoping (#412)

    private let otherKey = Data(repeating: 7, count: 32)

    private func host(_ key: Data, session: String?) -> NotificationRegistrationOwner {
        NotificationRegistrationOwner(deviceToken: "a1b2c3", key: key, session: session)
    }

    /// One raw entry of device token a1b2c3; `session: nil` omits the field
    /// the way an older app wrote it.
    private func device(
        _ key: Data, session: String?, done: Bool = true, extra: String = ""
    ) -> String {
        let sessionField = session.map { #","session":"\#($0)""# } ?? ""
        return #"{"token":"a1b2c3","key":"\#(key.base64URLEncodedString())","env":"production""#
            + sessionField + #","notify":{"blocked":true,"done":\#(done)}"# + extra + "}"
    }

    private func rawFile(_ devices: String...) throws -> NotificationRegistrationFile {
        try NotificationRegistrationFile.decode(
            Data(#"{"v":1,"devices":[\#(devices.joined(separator: ","))]}"#.utf8))
    }

    private func sessions(
        of owner: NotificationRegistrationOwner, in file: NotificationRegistrationFile
    ) -> [String?] {
        file.devices
            .filter { $0["key"]?.stringValue == owner.key.base64URLEncodedString() }
            .map { $0["session"]?.stringValue }
    }

    @Test func theOwnEntryIsTheOneCarryingTheHostsKeyNotJustTheDeviceToken() throws {
        let file = try rawFile(device(otherKey, session: "", done: false))

        #expect(file.preferences(for: host(key, session: "")) == nil)
        #expect(
            file.preferences(for: host(otherKey, session: ""))
                == NotificationTriggerPreferences(blocked: true, done: false))
    }

    @Test func aLegacyEntryReadsAsRegisteredOnlyForTheHostWhoseKeyItCarries() throws {
        let file = try rawFile(device(key, session: nil, done: false))

        #expect(
            file.preferences(for: host(key, session: "work"))
                == NotificationTriggerPreferences(blocked: true, done: false))
        #expect(file.preferences(for: host(otherKey, session: "work")) == nil)
    }

    @Test func normalizingMovesALegacyOwnEntryToTheHostsSessionKeepingItsFields() throws {
        let legacy = try rawFile(
            device(
                key, session: nil,
                extra: #","future_field":"kept","live_activity":{"token":"la","started_at":"t"}"#))
        let owner = host(key, session: "work")

        let normalized = legacy.normalized(for: owner)

        #expect(sessions(of: owner, in: normalized) == ["work"])
        let entry = try #require(normalized.devices.first)
        #expect(entry["future_field"]?.stringValue == "kept")
        #expect(entry["live_activity"]?["token"]?.stringValue == "la")
        #expect(normalized.normalized(for: owner) == normalized)
    }

    @Test func normalizingFollowsAnEditedSession() throws {
        let owner = host(key, session: "new")

        let normalized = try rawFile(device(key, session: "old")).normalized(for: owner)

        #expect(sessions(of: owner, in: normalized) == ["new"])
    }

    @Test func normalizingDropsTheOwnEntryWhenAnotherHostHoldsTheSlot() throws {
        let owner = host(key, session: "work")
        let original = try rawFile(device(key, session: nil), device(otherKey, session: "work"))

        let normalized = original.normalized(for: owner)

        #expect(normalized.preferences(for: owner) == nil)
        #expect(sessions(of: host(otherKey, session: "work"), in: normalized) == ["work"])
        #expect(normalized.devices.count == 1)
    }

    @Test func normalizingCollapsesDuplicateOwnEntriesKeepingTheCurrentSession() throws {
        let owner = host(key, session: "work")
        let original = try rawFile(
            device(key, session: "", done: false), device(key, session: "work", done: true))

        let normalized = original.normalized(for: owner)

        #expect(sessions(of: owner, in: normalized) == ["work"])
        #expect(normalized.preferences(for: owner)?.done == true)
    }

    @Test func normalizingWithoutAKnownSessionOrAnOwnEntryChangesNothing() throws {
        let original = try rawFile(device(key, session: nil), device(otherKey, session: "x"))

        #expect(original.normalized(for: host(key, session: nil)) == original)
        #expect(original.normalized(for: host(Data(count: 32), session: "x")) == original)
    }

    @Test func registeringTakesTheSlotAndDropsOwnDuplicatesButKeepsOtherSessions() throws {
        let original = try rawFile(
            device(otherKey, session: "work"),
            device(key, session: nil, extra: #","live_activity":{"token":"la","started_at":"t"}"#),
            device(key, session: "elsewhere"),
            device(Data(repeating: 3, count: 32), session: "other"),
            #"{"token":"ffff","key":"zz","session":"work"}"#)
        let entry = NotificationDeviceEntry(
            token: APNSDeviceToken(hex: "a1b2c3", environment: .production),
            key: key, session: "work",
            notify: NotificationTriggerPreferences(blocked: true, done: false))

        let registered = original.registering(entry)

        #expect(sessions(of: entry.owner, in: registered) == ["work"])
        #expect(registered.preferences(for: entry.owner) == entry.notify)
        #expect(registered.liveActivity(for: entry.owner)?.token == "la")
        #expect(registered.preferences(for: host(otherKey, session: "work")) == nil)
        #expect(registered.devices.count == 3)
        #expect(registered.devices.contains { $0["token"]?.stringValue == "ffff" })
        #expect(
            registered.preferences(for: host(Data(repeating: 3, count: 32), session: "other"))
                != nil)
    }

    @Test func disablingRemovesEveryOwnEntryAndNothingElse() throws {
        let original = try rawFile(
            device(key, session: ""), device(key, session: "x"), device(otherKey, session: ""))

        let removed = original.removing(host(key, session: ""))

        #expect(removed.devices.count == 1)
        #expect(removed.preferences(for: host(otherKey, session: "")) != nil)
    }

    @Test func settingALiveActivityTokenStripsItElsewhereEvenWhenUnregistered() throws {
        let laOn = #","live_activity":{"token":"la1","started_at":"t","future_la":"kept"}"#
        let original = try rawFile(
            device(otherKey, session: "old", extra: laOn),
            device(Data(repeating: 3, count: 32), session: "x",
                extra: #","live_activity":{"token":"la2","started_at":"t"}"#))
        let unregistered = host(key, session: "work")

        let stripped = original.strippingLiveActivity(token: "la1", keepingOwnEntryOf: unregistered)

        #expect(stripped.devices[0]["live_activity"] == nil)
        #expect(stripped.devices[1]["live_activity"]?["token"]?.stringValue == "la2")
        #expect(throws: NotificationRegistrationError.deviceNotRegistered) {
            try stripped.settingLiveActivity(
                token: "la1", startedAt: Date(timeIntervalSince1970: 0), for: unregistered)
        }

        let registered = try rawFile(device(key, session: "work"), device(otherKey, session: "old", extra: laOn))
            .settingLiveActivity(
                token: "la1", startedAt: Date(timeIntervalSince1970: 0), for: unregistered)
        #expect(registered.liveActivity(for: unregistered)?.token == "la1")
        #expect(registered.devices[1]["live_activity"] == nil)
    }

    @Test func liveActivityWritesNeverTouchAnotherHostInTheSameSession() throws {
        let hostA = host(key, session: "work")
        let hostB = host(otherKey, session: "work")
        let original = try rawFile(
            device(key, session: "work", extra: #","live_activity":{"token":"laA","started_at":"t"}"#),
            device(otherKey, session: "work",
                extra: #","live_activity":{"token":"laB","started_at":"t","pinned_pane_ids":["w1:p1"]}"#))
        let bBefore = original.devices[1]
        let layout = AgentRowLayout(rows: [[.init(.workspace)]])

        let set = try original.settingLiveActivity(
            token: "laA2", startedAt: Date(timeIntervalSince1970: 0), for: hostA,
            pinnedPaneIDs: ["w9:p9"], rowLayout: layout, hostName: "A")
        let pinned = try original.settingLiveActivityPinnedPaneIDs(["w9:p9"], for: hostA)
        let laidOut = try original.settingLiveActivityRowLayout(layout, hostName: "A", for: hostA)
        let cleared = original.clearingLiveActivity(token: "laA", for: hostA)
        let clearedWithBsToken = original.clearingLiveActivity(token: "laB", for: hostA)

        for result in [set, pinned, laidOut, cleared, clearedWithBsToken] {
            #expect(result.devices[1] == bBefore)
        }
        #expect(set.liveActivity(for: hostA)?.token == "laA2")
        #expect(pinned.liveActivity(for: hostA)?.pinnedPaneIDs == ["w9:p9"])
        #expect(cleared.liveActivity(for: hostA) == nil)
        #expect(clearedWithBsToken == original)
        #expect(original.liveActivity(for: hostB)?.pinnedPaneIDs == ["w1:p1"])
    }

    @Test func clearingWithoutAnOwnEntryRemovesOnlyTheGivenToken() throws {
        let original = try rawFile(
            device(otherKey, session: "work", extra: #","live_activity":{"token":"laB","started_at":"t"}"#),
            device(Data(repeating: 3, count: 32), session: "x",
                extra: #","live_activity":{"token":"stale","started_at":"t"}"#))
        let unregistered = host(key, session: "work")

        #expect(original.clearingLiveActivity(token: nil, for: unregistered) == original)
        #expect(original.clearingLiveActivity(token: "gone", for: nil) == original)
        let cleared = original.clearingLiveActivity(token: "stale", for: unregistered)
        #expect(cleared.devices[0] == original.devices[0])
        #expect(cleared.devices[1]["live_activity"] == nil)
    }
}
