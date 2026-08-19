import Foundation

/// Why Notification Registration failed. A closed taxonomy so the UI can
/// distinguish "install the plugin on this Host" from "the write broke"
/// (#72 acceptance criteria) instead of string-matching. Transport-level
/// failures (unreachable Host, timeout, cancellation) stay `TransportError`.
enum NotificationRegistrationError: Error, Sendable, Equatable {
    /// The Heeler plugin is not installed — or is disabled — on the
    /// Host, so nothing there would ever read a registration file.
    case pluginNotInstalled
    /// The plugin probe broke: `herdr plugin list` or `herdr plugin
    /// config-dir` could not run or printed something unparseable, so the
    /// plugin's presence and config dir are unknown.
    case pluginProbeFailed(detail: String)
    /// The registration file exists but could not be read.
    case readFailed(detail: String)
    /// The registration file could not be replaced atomically.
    case writeFailed(detail: String)
    /// The Host's registration file declares a version this build does not
    /// write. Clobbering it could destroy a newer app's registrations, so
    /// the ceremony refuses (the v1 contract bumps `v` only on breaking
    /// changes, honored by plugin and app together).
    case unsupportedFileVersion(Int)
    /// This device has no entry in the Host's registration file, so a Live
    /// Activity token cannot be attached (fail closed).
    case deviceNotRegistered
}

/// The `notify` preference flags of a registration file entry: which Agent
/// Status transitions this device wants pushed. Per the v1 contract a
/// missing flag means "do not send" (fail closed), so both are always
/// written explicitly.
struct NotificationTriggerPreferences: Sendable, Equatable {
    var blocked: Bool
    var done: Bool

    init(blocked: Bool = true, done: Bool = true) {
        self.blocked = blocked
        self.done = done
    }
}

/// One v1 device entry as this device writes it: the APNs token (with its
/// environment), the Host's Notification Key, and the notify flags.
struct NotificationDeviceEntry: Sendable, Equatable {
    let token: APNSDeviceToken
    /// Raw 32-byte Notification Key; encoded as unpadded base64url on the
    /// wire, like every cross-implementation byte field.
    let key: Data
    let notify: NotificationTriggerPreferences

    /// The wire form of this entry, keyed per the contract table.
    fileprivate var wireValue: JSONValue {
        .object([
            "token": .string(token.hex),
            "key": .string(key.base64URLEncodedString()),
            "env": .string(token.environment.rawValue),
            "notify": .object([
                "blocked": .bool(notify.blocked),
                "done": .bool(notify.done),
            ]),
        ])
    }
}

/// The `live_activity` field of a device entry: the per-activity push token
/// and when the app started that activity. `startedAt` is the ISO 8601
/// string as stored, so a rewrite can be compared without re-formatting.
/// `pinnedPaneIDs` is most-recently-pinned first; a missing or malformed
/// field reads as empty (docs/agents/live-activity-contract.md).
struct LiveActivityRegistration: Sendable, Equatable {
    var token: String
    var startedAt: String
    var pinnedPaneIDs: [String] = []
}

/// The Notification Registration file v1 (`plugin/README.md`): the whole
/// `notifications.json` a Host holds, keyed one entry per device token.
/// Entries this device did not write are carried verbatim as JSON — a newer
/// app's additive v1 metadata on another device's entry must survive a
/// rewrite from this one — and only the entry matching a given token is ever
/// replaced or removed.
struct NotificationRegistrationFile: Sendable, Equatable {
    static let version = 1

    /// Every device entry, in file order; foreign entries preserved verbatim.
    private(set) var devices: [JSONValue]

    /// A file with no registered devices ("empty means no notifications").
    init() {
        devices = []
    }

    private init(devices: [JSONValue]) {
        self.devices = devices
    }

    /// Decodes the file a Host currently holds. Absent (`nil`) or corrupt
    /// content decodes as empty: the plugin reader treats both as "send
    /// nothing", and the next registration self-heals the file. A parseable
    /// file declaring a different version belongs to a different contract
    /// revision and is refused instead of clobbered.
    static func decode(_ data: Data?) throws -> NotificationRegistrationFile {
        guard let data, let wire = try? JSONDecoder().decode(WireFile.self, from: data) else {
            return NotificationRegistrationFile()
        }
        guard wire.v == version else {
            throw NotificationRegistrationError.unsupportedFileVersion(wire.v)
        }
        return NotificationRegistrationFile(devices: wire.devices ?? [])
    }

    /// Merges `entry`'s keys over the existing object carrying that token,
    /// or appends one: re-registration stays idempotent and additive fields
    /// this type does not own (`live_activity`, future metadata) survive.
    func upserting(_ entry: NotificationDeviceEntry) -> NotificationRegistrationFile {
        var updated = devices
        if let index = updated.firstIndex(where: { $0["token"]?.stringValue == entry.token.hex }) {
            updated[index].mergeKeys(from: entry.wireValue)
        } else {
            updated.append(entry.wireValue)
        }
        return NotificationRegistrationFile(devices: updated)
    }

    /// Drops the entry carrying `token`; removing an entry revokes that
    /// device.
    func removing(token: String) -> NotificationRegistrationFile {
        NotificationRegistrationFile(
            devices: devices.filter { $0["token"]?.stringValue != token })
    }

    func containsDevice(token: String) -> Bool {
        devices.contains { $0["token"]?.stringValue == token }
    }

    /// Writes `live_activity` on the matching device entry and leaves every
    /// other field on that object untouched. Merges into an existing
    /// `live_activity` object so unknown fields and a prior pin list
    /// survive. An unknown token is a no-op; the ceremony refuses that case
    /// instead of inventing an entry.
    func settingLiveActivity(
        token: String,
        startedAt: Date,
        forDeviceToken deviceToken: String,
        pinnedPaneIDs: [String] = []
    ) -> NotificationRegistrationFile {
        mutatingDevice(token: deviceToken) { entry in
            var live = objectValue(entry["live_activity"]) ?? .object([:])
            live.setKey("token", to: .string(token))
            live.setKey("started_at", to: .string(Self.iso8601String(from: startedAt)))
            live.setKey("pinned_pane_ids", to: .array(pinnedPaneIDs.map { .string($0) }))
            entry.setKey("live_activity", to: live)
        }
    }

    /// Writes `pinned_pane_ids` on an existing `live_activity` object and
    /// leaves token, started_at, and unknown fields untouched. No-op when
    /// the device is missing or has no `live_activity` yet.
    func settingLiveActivityPinnedPaneIDs(
        _ pinnedPaneIDs: [String], forDeviceToken deviceToken: String
    ) -> NotificationRegistrationFile {
        mutatingDevice(token: deviceToken) { entry in
            guard entry["live_activity"] != nil else { return }
            var live = objectValue(entry["live_activity"]) ?? .object([:])
            live.setKey("pinned_pane_ids", to: .array(pinnedPaneIDs.map { .string($0) }))
            entry.setKey("live_activity", to: live)
        }
    }

    /// Drops `live_activity` from the matching device entry, preserving
    /// every other field. An unknown token is a no-op.
    func clearingLiveActivity(forDeviceToken deviceToken: String) -> NotificationRegistrationFile {
        mutatingDevice(token: deviceToken) { entry in
            entry.setKey("live_activity", to: nil)
        }
    }

    /// The `live_activity` field of the entry carrying `deviceToken`, nil
    /// when that device is not registered or the field is missing/mistyped.
    func liveActivity(forDeviceToken deviceToken: String) -> LiveActivityRegistration? {
        guard let entry = devices.first(where: { $0["token"]?.stringValue == deviceToken }),
            let liveToken = entry["live_activity"]?["token"]?.stringValue, !liveToken.isEmpty,
            let startedAt = entry["live_activity"]?["started_at"]?.stringValue, !startedAt.isEmpty
        else { return nil }
        return LiveActivityRegistration(
            token: liveToken,
            startedAt: startedAt,
            pinnedPaneIDs: Self.pinnedPaneIDs(from: entry["live_activity"]?["pinned_pane_ids"]))
    }

    /// Lenient reader for `live_activity.pinned_pane_ids`. Missing, null, a
    /// non-array, or any non-string entry yields an empty list — never a throw.
    static func pinnedPaneIDs(from value: JSONValue?) -> [String] {
        guard case .array(let items)? = value else { return [] }
        var ids: [String] = []
        ids.reserveCapacity(items.count)
        for item in items {
            guard case .string(let id) = item else { return [] }
            ids.append(id)
        }
        return ids
    }

    /// The notify flags of the entry carrying `token`, nil when that device
    /// is not registered. A missing or mistyped flag reads as off — the same
    /// fail-closed reading the plugin's notify hook applies (v1 contract).
    func preferences(token: String) -> NotificationTriggerPreferences? {
        guard let entry = devices.first(where: { $0["token"]?.stringValue == token }) else {
            return nil
        }
        return NotificationTriggerPreferences(
            blocked: entry["notify"]?["blocked"] == .bool(true),
            done: entry["notify"]?["done"] == .bool(true))
    }

    /// The serialized file for an atomic whole-file replace. Sorted keys keep
    /// the output deterministic; the v1 contract imposes no canonical order.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(WireFile(v: Self.version, devices: devices))
    }

    private func objectValue(_ value: JSONValue?) -> JSONValue? {
        guard let value, case .object = value else { return nil }
        return value
    }

    private func mutatingDevice(
        token: String, update: (inout JSONValue) -> Void
    ) -> NotificationRegistrationFile {
        var updated = devices
        guard let index = updated.firstIndex(where: { $0["token"]?.stringValue == token }) else {
            return self
        }
        update(&updated[index])
        return NotificationRegistrationFile(devices: updated)
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// The wire shape: `v` stays an integer end to end (`JSONValue` would
    /// round-trip it through Double), devices stay schema-free.
    private struct WireFile: Codable {
        let v: Int
        let devices: [JSONValue]?

        init(v: Int, devices: [JSONValue]) {
            self.v = v
            self.devices = devices
        }
    }
}

extension JSONValue {
    fileprivate mutating func mergeKeys(from other: JSONValue) {
        guard case .object(var fields) = self, case .object(let incoming) = other else {
            self = other
            return
        }
        for (key, value) in incoming {
            fields[key] = value
        }
        self = .object(fields)
    }

    fileprivate mutating func setKey(_ key: String, to value: JSONValue?) {
        guard case .object(var fields) = self else { return }
        if let value {
            fields[key] = value
        } else {
            fields.removeValue(forKey: key)
        }
        self = .object(fields)
    }
}
