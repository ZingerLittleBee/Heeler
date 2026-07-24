import Foundation
import Observation

/// The app-side custom Push Relay base URL (#76, ADR 0008). A self-builder who
/// ships their own bundle id and APNs key can point every Host's plugin at
/// their own relay instead of the developer-hosted default; the value is
/// written into each Host's `notify.json` at Notification Registration.
///
/// Empty is the default and means "leave the plugin's config alone": the app
/// never writes `relay_url`, so the plugin keeps whatever it was configured
/// with (the default relay, once deployed). Only an http(s) base URL is
/// accepted — a malformed entry yields no `URL`, so a typo never lands on a
/// Host, and the settings screen can flag it instead.
@MainActor
@Observable
final class NotificationRelaySettings {
    private static let defaultsKey = "notification-relay-url"

    /// The raw text the user typed, persisted verbatim so the field round-trips
    /// (including an in-progress typo the user is still editing).
    var rawValue: String {
        didSet {
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                defaults.removeObject(forKey: Self.defaultsKey)
            } else {
                defaults.set(trimmed, forKey: Self.defaultsKey)
            }
        }
    }

    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rawValue = defaults.string(forKey: Self.defaultsKey) ?? ""
    }

    /// The validated base URL, or nil when the field is empty or malformed —
    /// the signal the registration ceremony reads as "do not touch notify.json".
    var relayURL: URL? {
        Self.validate(rawValue)
    }

    /// Whether the current text is non-empty but not a usable relay URL, so the
    /// settings screen can flag a typo instead of silently ignoring it.
    var hasInvalidEntry: Bool {
        !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && relayURL == nil
    }

    /// Parses a custom relay base URL: an absolute http(s) URL with a host and
    /// no query or fragment. A path prefix is allowed (the relay may be
    /// deployed under a subpath); the plugin appends `/push` to whatever base
    /// it is given, so a query or fragment would only be a mistake.
    static func validate(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            let components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty,
            components.query == nil, components.fragment == nil,
            let url = components.url
        else { return nil }
        return url
    }
}
