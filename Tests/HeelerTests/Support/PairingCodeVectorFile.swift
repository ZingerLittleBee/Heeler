import Foundation

/// The shared Pairing Code vectors from `plugin/test-vectors/`, the single
/// source of truth for the envelope across the Node plugin and this app
/// (ADR 0007). The JSON files are bundled into the test target as resources
/// so the Swift tests exercise exactly the same cases as the Node tests;
/// the v2 file (ADR 0021) is consumed by the Swift tests only.
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
        /// The Herdr Endpoint's socket (`sock`); absent when the code must
        /// decode without an endpoint.
        let socketPath: String?
        /// The Herdr Endpoint's launcher (`herdr`), present with `socketPath`.
        let herdrPath: String?
    }

    struct Invalid: Decodable, Sendable, CustomStringConvertible {
        let name: String
        let code: String
        /// The expected error identifier, e.g. "bad_prefix".
        let error: String
        var description: String { name }
    }

    /// `pairing-code-v1.json`, shared with the Node plugin tests.
    static let shared: PairingCodeVectorFile = load("pairing-code-v1")
    /// `pairing-code-v2.json`: version 2 codes, which only the app decodes.
    static let v2: PairingCodeVectorFile = load("pairing-code-v2")

    private static func load(_ resource: String) -> PairingCodeVectorFile {
        guard
            let url = Bundle(for: BundleLocator.self)
                .url(forResource: resource, withExtension: "json")
        else {
            fatalError("\(resource).json is missing from the test bundle")
        }
        do {
            return try JSONDecoder().decode(PairingCodeVectorFile.self, from: Data(contentsOf: url))
        } catch {
            fatalError("shared pairing vectors \(resource).json failed to load: \(error)")
        }
    }

    private final class BundleLocator {}
}
