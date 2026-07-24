import Foundation

/// The shared Pairing Code v1 vectors from `plugin/test-vectors/`, the single
/// source of truth for the envelope across the Node plugin and this app
/// (ADR 0007). The JSON file is bundled into the test target as a resource so
/// the Swift tests exercise exactly the same cases as the Node tests.
struct PairingCodeVectorFile: Decodable, Sendable {
    let valid: [Valid]
    let invalid: [Invalid]

    struct Valid: Decodable, Sendable, CustomStringConvertible {
        let name: String
        let code: String
        let payload: Payload
        var description: String { name }
    }

    struct Payload: Decodable, Sendable {
        let addresses: [String]
        let port: Int
        let username: String
        let hostKeyFingerprint: String
        /// Raw 32-byte Bootstrap Key seed as unpadded base64url (wire encoding).
        let bootstrapSeed: String?
        let expiresAt: Int?
    }

    struct Invalid: Decodable, Sendable, CustomStringConvertible {
        let name: String
        let code: String
        /// The expected error identifier, e.g. "bad_prefix".
        let error: String
        var description: String { name }
    }

    static let shared: PairingCodeVectorFile = {
        guard
            let url = Bundle(for: BundleLocator.self)
                .url(forResource: "pairing-code-v1", withExtension: "json")
        else {
            fatalError("pairing-code-v1.json is missing from the test bundle")
        }
        do {
            return try JSONDecoder().decode(PairingCodeVectorFile.self, from: Data(contentsOf: url))
        } catch {
            fatalError("shared pairing vectors failed to load: \(error)")
        }
    }()

    private final class BundleLocator {}
}
