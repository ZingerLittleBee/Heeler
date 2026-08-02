import Foundation

/// The plugin-side `notify.json` config file (`plugin/README.md`) as this app
/// reads and rewrites it. The app owns exactly one field — `relay_url`, the
/// custom Push Relay base URL a self-builder points their plugin at (#76) —
/// but the plugin owns others (`debounce_ms`, `retry_delay_ms`) and future
/// revisions may add more, so every field this app does not understand is
/// carried verbatim through a rewrite, exactly like a foreign device entry in
/// the registration file. Unlike that file this config has no version gate: it
/// is a flat settings bag the plugin parses leniently.
struct NotificationConfigFile: Sendable, Equatable {
    /// The `relay_url` key of the registration file's sibling config.
    static let relayURLKey = "relay_url"

    /// Every field, preserved verbatim; foreign keys survive a rewrite.
    private var fields: [String: JSONValue]

    /// An empty config: what the app writes onto a Host that had none.
    init() {
        fields = [:]
    }

    private init(fields: [String: JSONValue]) {
        self.fields = fields
    }

    /// Decodes the config a Host currently holds. Absent (`nil`), corrupt, or
    /// non-object content decodes as empty — the same lenient reading the
    /// plugin applies, and the only safe base for a merge that adds `relay_url`
    /// without inventing the plugin's other knobs.
    static func decode(_ data: Data?) throws -> NotificationConfigFile {
        guard let data,
            let value = try? JSONDecoder().decode(JSONValue.self, from: data),
            case .object(let fields) = value
        else {
            return NotificationConfigFile()
        }
        return NotificationConfigFile(fields: fields)
    }

    /// The current `relay_url`, trailing slash trimmed to match how the plugin
    /// normalizes it; nil when unset or not a string.
    var relayURL: String? {
        Self.normalize(fields[Self.relayURLKey]?.stringValue)
    }

    /// Sets `relay_url` to `url` (trailing slash trimmed), preserving every
    /// other field. The merge only ever touches the one key this app owns.
    func settingRelayURL(_ url: String) -> NotificationConfigFile {
        var updated = fields
        updated[Self.relayURLKey] = .string(Self.normalize(url) ?? url)
        return NotificationConfigFile(fields: updated)
    }

    /// The serialized config for an atomic whole-file replace. Sorted keys keep
    /// the output deterministic; the plugin imposes no canonical order.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(fields)
    }

    private static func normalize(_ url: String?) -> String? {
        guard let url else { return nil }
        var trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.isEmpty ? nil : trimmed
    }
}
