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
    /// The Host has no entry for this device (none carries the device token
    /// and the Host's Notification Key), so a Live Activity token cannot be
    /// attached (fail closed).
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
/// environment), the Host's Notification Key, the herdr session the Host
/// targets, and the notify flags.
struct NotificationDeviceEntry: Sendable, Equatable {
    let token: APNSDeviceToken
    /// Raw 32-byte Notification Key; encoded as unpadded base64url on the
    /// wire, like every cross-implementation byte field.
    let key: Data
    /// The herdr session the Host targets: "" for the default session,
    /// otherwise the session name. The plugin delivers an entry only to hooks
    /// running in that session.
    let session: String
    let notify: NotificationTriggerPreferences

    /// Whose entry this is, for finding it again in a file.
    var owner: NotificationRegistrationOwner {
        NotificationRegistrationOwner(deviceToken: token.hex, key: key, session: session)
    }

    /// The wire form of this entry, keyed per the contract table.
    fileprivate var wireValue: JSONValue {
        .object([
            "token": .string(token.hex),
            "key": .string(key.base64URLEncodedString()),
            "env": .string(token.environment.rawValue),
            "session": .string(session),
            "notify": .object([
                "blocked": .bool(notify.blocked),
                "done": .bool(notify.done),
            ]),
        ])
    }
}

/// Identifies one Host's own entry in its registration file: this device's
/// APNs token plus that Host's Notification Key. Notification Keys are random
/// per Host, so an entry carrying the key always belongs to that Host; the
/// device token alone does not (#412: Hosts on several herdr sessions of one
/// remote user share one file). `session` is a field of the entry, not part
/// of its identity.
struct NotificationRegistrationOwner: Sendable, Equatable {
    /// Hex APNs device token.
    let deviceToken: String
    /// Raw 32-byte Notification Key of the Host.
    let key: Data
    /// The herdr session the Host targets now ("" is the default session).
    /// nil when it is unknown (the Host left the catalog): the entry is
    /// still found by key, but nothing is normalized toward a session.
    let session: String?

    fileprivate func owns(_ device: JSONValue) -> Bool {
        device["token"]?.stringValue == deviceToken
            && device["key"]?.stringValue == key.base64URLEncodedString()
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
/// `notifications.json` a Host holds. Entries this device did not write are
/// carried verbatim as JSON — a newer app's additive v1 metadata on another
/// device's entry must survive a rewrite from this one — and a Host only
/// ever reads, replaces, or removes its own entry (see
/// `NotificationRegistrationOwner`). The app keeps at most one entry per
/// (device token, session).
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

    /// Writes the Host's own entry for the entry's session: merges over the
    /// existing own entry (so `live_activity` and fields this type does not
    /// own survive) or appends one. Any other entry of this device token in
    /// the same session is dropped (last writer wins, keeping one entry per
    /// token and session), as are duplicate own entries.
    func registering(_ entry: NotificationDeviceEntry) -> NotificationRegistrationFile {
        let owner = entry.owner
        var updated = devices
        let own: Int
        if let index = ownIndex(of: owner) {
            updated[index].mergeKeys(from: entry.wireValue)
            own = index
        } else {
            updated.append(entry.wireValue)
            own = updated.count - 1
        }
        let kept = updated.indices.filter { index in
            guard index != own, updated[index]["token"]?.stringValue == owner.deviceToken else {
                return true
            }
            return !owner.owns(updated[index])
                && updated[index]["session"]?.stringValue != entry.session
        }
        return NotificationRegistrationFile(devices: kept.map { updated[$0] })
    }

    /// Drops every entry of this Host (device token and Notification Key);
    /// other Hosts' entries of the same device stay.
    func removing(_ owner: NotificationRegistrationOwner) -> NotificationRegistrationFile {
        NotificationRegistrationFile(devices: devices.filter { !owner.owns($0) })
    }

    /// Drops every entry carrying this Notification Key, whatever its device
    /// token. The key is random per Host and never leaves this device's
    /// Keychain, so each such entry is this device's own for that Host, an
    /// older APNs token's included.
    func removing(key: Data) -> NotificationRegistrationFile {
        let encoded = key.base64URLEncodedString()
        return NotificationRegistrationFile(
            devices: devices.filter { $0["key"]?.stringValue != encoded })
    }

    /// Moves the Host's own entry to the session the Host targets now. An
    /// entry from an older app (no `session`) or from before a session edit
    /// is rewritten in place, keeping `live_activity` and unknown fields —
    /// unless another Host already holds this device's slot in that
    /// session, in which case the stale own entry is dropped and the Host
    /// reads as unregistered. Duplicate own entries collapse to one. A nil
    /// session or a missing own entry changes nothing.
    func normalized(for owner: NotificationRegistrationOwner) -> NotificationRegistrationFile {
        guard let session = owner.session, let own = ownIndex(of: owner) else { return self }
        var updated = devices.indices
            .filter { $0 == own || !owner.owns(devices[$0]) }
            .map { devices[$0] }
        guard let index = updated.firstIndex(where: owner.owns),
            updated[index]["session"]?.stringValue != session
        else { return NotificationRegistrationFile(devices: updated) }
        let slotTaken = updated.indices.contains { other in
            other != index
                && updated[other]["token"]?.stringValue == owner.deviceToken
                && updated[other]["session"]?.stringValue == session
        }
        if slotTaken {
            updated.remove(at: index)
        } else {
            updated[index].setKey("session", to: .string(session))
        }
        return NotificationRegistrationFile(devices: updated)
    }

    /// Removes `live_activity` carrying the Live Activity push token
    /// `liveToken` from every entry except the Host's own. A token belongs to
    /// one activity of one Host; a copy elsewhere is stale (for example left
    /// on a previous own entry) and would push to the wrong session.
    func strippingLiveActivity(
        token liveToken: String, keepingOwnEntryOf owner: NotificationRegistrationOwner?
    ) -> NotificationRegistrationFile {
        let own = owner.flatMap(ownIndex(of:))
        var updated = devices
        for index in updated.indices where index != own {
            guard updated[index]["live_activity"]?["token"]?.stringValue == liveToken else {
                continue
            }
            updated[index].setKey("live_activity", to: nil)
        }
        return NotificationRegistrationFile(devices: updated)
    }

    /// Writes `live_activity` on the Host's own entry after stripping the
    /// same Live Activity token from every other entry, and leaves every
    /// other field untouched. Merges into an existing `live_activity` object
    /// so unknown fields and a prior pin list survive. Throws
    /// `deviceNotRegistered` when the Host has no entry: the alert key the
    /// plugin needs cannot be invented here.
    func settingLiveActivity(
        token: String,
        startedAt: Date,
        for owner: NotificationRegistrationOwner,
        pinnedPaneIDs: [String] = [],
        rowLayout: AgentRowLayout? = nil,
        hostName: String? = nil
    ) throws -> NotificationRegistrationFile {
        try strippingLiveActivity(token: token, keepingOwnEntryOf: owner)
            .mutatingOwnEntry(of: owner) { entry in
                var live = objectValue(entry["live_activity"]) ?? .object([:])
                live.setKey("token", to: .string(token))
                live.setKey("started_at", to: .string(Self.iso8601String(from: startedAt)))
                live.setKey("pinned_pane_ids", to: .array(pinnedPaneIDs.map { .string($0) }))
                if let rowLayout { live.setKey("row_layout", to: rowLayout.activityRegistrationValue) }
                if let hostName { live.setKey("host_name", to: .string(hostName)) }
                entry.setKey("live_activity", to: live)
            }
    }

    /// Writes `pinned_pane_ids` on the own entry's existing `live_activity`
    /// object and leaves token, started_at, and unknown fields untouched.
    /// No-op without a `live_activity` yet; throws `deviceNotRegistered`
    /// when the Host has no entry.
    func settingLiveActivityPinnedPaneIDs(
        _ pinnedPaneIDs: [String], for owner: NotificationRegistrationOwner
    ) throws -> NotificationRegistrationFile {
        try mutatingOwnEntry(of: owner) { entry in
            guard var live = objectValue(entry["live_activity"]) else { return }
            live.setKey("pinned_pane_ids", to: .array(pinnedPaneIDs.map { .string($0) }))
            entry.setKey("live_activity", to: live)
        }
    }

    /// Updates the own entry's layout without replacing tokens, pins, or
    /// unknown fields; throws `deviceNotRegistered` when the Host has no
    /// entry.
    func settingLiveActivityRowLayout(
        _ layout: AgentRowLayout, hostName: String? = nil, for owner: NotificationRegistrationOwner
    ) throws -> NotificationRegistrationFile {
        try mutatingOwnEntry(of: owner) { entry in
            guard var live = objectValue(entry["live_activity"]) else { return }
            live.setKey("row_layout", to: layout.activityRegistrationValue)
            if let hostName { live.setKey("host_name", to: .string(hostName)) }
            entry.setKey("live_activity", to: live)
        }
    }

    /// Drops `live_activity` from the Host's own entry when it carries
    /// `liveToken` (any token when `liveToken` is nil: the field is this
    /// Host's own). Without an own entry, drops it from whichever entry
    /// carries `liveToken`. Another Host's `live_activity` with a different
    /// token is never touched. Every other field is preserved.
    func clearingLiveActivity(
        token liveToken: String?, for owner: NotificationRegistrationOwner?
    ) -> NotificationRegistrationFile {
        var updated = devices
        if let own = owner.flatMap(ownIndex(of:)) {
            if liveToken == nil
                || updated[own]["live_activity"]?["token"]?.stringValue == liveToken
            {
                updated[own].setKey("live_activity", to: nil)
            }
        } else if let liveToken {
            for index in updated.indices
            where updated[index]["live_activity"]?["token"]?.stringValue == liveToken {
                updated[index].setKey("live_activity", to: nil)
            }
        }
        return NotificationRegistrationFile(devices: updated)
    }

    /// The `live_activity` field of the Host's own entry, nil when the Host
    /// is not registered or the field is missing/mistyped.
    func liveActivity(for owner: NotificationRegistrationOwner) -> LiveActivityRegistration? {
        guard let own = ownIndex(of: owner) else { return nil }
        let entry = devices[own]
        guard let liveToken = entry["live_activity"]?["token"]?.stringValue, !liveToken.isEmpty,
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

    /// The notify flags of the Host's own entry, nil when the Host is not
    /// registered (no entry carries this device token and the Host's key). A
    /// missing or mistyped flag reads as off — the same fail-closed reading
    /// the plugin's notify hook applies (v1 contract).
    func preferences(for owner: NotificationRegistrationOwner) -> NotificationTriggerPreferences? {
        guard let own = ownIndex(of: owner) else { return nil }
        let entry = devices[own]
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

    /// The Host's own entry: the one carrying this device token and the
    /// Host's key, preferring the one already in the Host's session when
    /// duplicates exist.
    private func ownIndex(of owner: NotificationRegistrationOwner) -> Int? {
        let candidates = devices.indices.filter { owner.owns(devices[$0]) }
        if let session = owner.session,
            let current = candidates.first(where: { devices[$0]["session"]?.stringValue == session })
        {
            return current
        }
        return candidates.first
    }

    private func objectValue(_ value: JSONValue?) -> JSONValue? {
        guard let value, case .object = value else { return nil }
        return value
    }

    private func mutatingOwnEntry(
        of owner: NotificationRegistrationOwner, update: (inout JSONValue) -> Void
    ) throws -> NotificationRegistrationFile {
        guard let index = ownIndex(of: owner) else {
            throw NotificationRegistrationError.deviceNotRegistered
        }
        var updated = devices
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

private extension AgentRowLayout {
    var activityRegistrationValue: JSONValue {
        .object([
            "rows": .array(normalizedForConsole().rows.map { row in
                .array(row.map { field in
                    var value: [String: JSONValue] = ["token": .string(field.token.rawValue)]
                    if let fg = field.fg { value["fg"] = .string(fg.rawValue) }
                    if let bold = field.bold { value["bold"] = .bool(bold) }
                    if let dim = field.dim { value["dim"] = .bool(dim) }
                    return .object(value)
                })
            }),
            "row_gap": .number(Double(rowGap)),
            "rows_by_agent": .object([:]),
        ])
    }
}
