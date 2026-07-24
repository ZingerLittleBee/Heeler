import Foundation

/// Why Notification Registration failed. A closed taxonomy so the UI can
/// distinguish "install the plugin on this Host" from "the write broke"
/// (#72 acceptance criteria) instead of string-matching. Transport-level
/// failures (unreachable Host, timeout, cancellation) stay `TransportError`.
enum NotificationRegistrationError: Error, Sendable, Equatable {
    /// The herdr-mobile plugin is not installed — or is disabled — on the
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

    /// Replaces the entry carrying `entry`'s token, or appends one: exactly
    /// how re-registration from the same device stays idempotent.
    func upserting(_ entry: NotificationDeviceEntry) -> NotificationRegistrationFile {
        var updated = devices
        if let index = updated.firstIndex(where: { $0["token"]?.stringValue == entry.token.hex }) {
            updated[index] = entry.wireValue
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

    /// The serialized file for an atomic whole-file replace. Sorted keys keep
    /// the output deterministic; the v1 contract imposes no canonical order.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(WireFile(v: Self.version, devices: devices))
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
