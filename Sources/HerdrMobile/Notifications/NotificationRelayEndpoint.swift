import Foundation

/// The production Push Relay endpoint shared by Notification Registration and
/// the settings surface. The plugin carries the same value as its runtime
/// default; changing the production endpoint requires updating both sides.
enum NotificationRelayEndpoint {
    static let productionBaseURLString = "https://herdr-apns.bybee.dev"

    /// The previous production endpoint. Treat it as the default rather than a
    /// custom override so existing installations migrate on their next
    /// Notification Registration.
    static let legacyProductionBaseURLString =
        "https://herdr-push-relay.69709991236.workers.dev"

    static var productionBaseURL: URL? {
        URL(string: productionBaseURLString)
    }

    static func resolve(customBaseURL: URL?) -> URL? {
        guard let customBaseURL else { return productionBaseURL }
        if normalized(customBaseURL.absoluteString) == legacyProductionBaseURLString {
            return productionBaseURL
        }
        return customBaseURL
    }

    static func isLegacyProductionBaseURL(_ value: String) -> Bool {
        normalized(value) == legacyProductionBaseURLString
    }

    private static func normalized(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}
