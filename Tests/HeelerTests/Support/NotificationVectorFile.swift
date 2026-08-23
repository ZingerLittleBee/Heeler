import Foundation

/// The shared notification envelope v1 vectors from `plugin/test-vectors/`,
/// the single source of truth for the encrypted Agent Notification payload
/// across the Node plugin and this app (ADR 0008). The JSON file is bundled
/// into the test target as a resource so the Swift tests exercise exactly the
/// same cases as the Node tests: the plugin proves the encrypt direction,
/// these tests prove the decrypt direction.
///
/// `payload.paneId` values that stand in for a herdr address use the observed
/// alphanumeric `w…:p…` family (uppercase included). Production code still
/// treats pane ids as opaque strings; these fixtures do not define a grammar.
struct NotificationVectorFile: Decodable, Sendable {
    let valid: [Valid]
    let invalid: [Invalid]

    struct Valid: Decodable, Sendable, CustomStringConvertible {
        let name: String
        /// Raw 32-byte Notification Key as unpadded base64url.
        let key: String
        /// The key id both ends must derive from `key`.
        let keyId: String
        /// The exact envelope wire string.
        let envelope: String
        let payload: Payload
        var description: String { name }
    }

    struct Payload: Decodable, Sendable {
        let paneId: String
        let agentKind: String
        let status: String
        let timestamp: Int
        /// The optional display fields; absent from vectors predating them.
        let project: String?
        let title: String?
    }

    struct Invalid: Decodable, Sendable, CustomStringConvertible {
        let name: String
        /// The key to attempt decryption with (deliberately wrong for the
        /// wrong-key case).
        let key: String
        let envelope: String
        /// The expected error identifier, e.g. "decrypt_failed".
        let error: String
        var description: String { name }
    }

    static let shared: NotificationVectorFile = {
        guard
            let url = Bundle(for: BundleLocator.self)
                .url(forResource: "notification-payload-v1", withExtension: "json")
        else {
            fatalError("notification-payload-v1.json is missing from the test bundle")
        }
        do {
            return try JSONDecoder().decode(
                NotificationVectorFile.self, from: Data(contentsOf: url))
        } catch {
            fatalError("shared notification vectors failed to load: \(error)")
        }
    }()

    private final class BundleLocator {}
}
