import Foundation

/// The shared Live Activity content envelope v1 vectors from
/// `plugin/test-vectors/`, the single source of truth for the encrypted
/// per-Host agent details across the Node plugin and this app. The JSON
/// file is bundled into the test target as a resource so both suites
/// exercise the same cases.
struct LiveActivityVectorFile: Decodable, Sendable {
    let valid: [Valid]
    let invalid: [Invalid]

    struct Valid: Decodable, Sendable, CustomStringConvertible {
        let name: String
        let key: String
        let keyId: String
        let envelope: String
        let payload: Payload
        let decodeOnly: Bool
        var description: String { name }

        enum CodingKeys: String, CodingKey {
            case name, key, keyId, envelope, payload, decodeOnly
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            key = try container.decode(String.self, forKey: .key)
            keyId = try container.decode(String.self, forKey: .keyId)
            envelope = try container.decode(String.self, forKey: .envelope)
            payload = try container.decode(Payload.self, forKey: .payload)
            decodeOnly = try container.decodeIfPresent(Bool.self, forKey: .decodeOnly) ?? false
        }
    }

    struct Payload: Decodable, Sendable {
        let host: String
        let agents: [Agent]
    }

    struct Agent: Decodable, Sendable {
        let pane: String
        let kind: String
        let status: String
        let title: String?
    }

    struct Invalid: Decodable, Sendable, CustomStringConvertible {
        let name: String
        let key: String
        let envelope: String
        let error: String
        var description: String { name }
    }

    static let shared: LiveActivityVectorFile = {
        guard
            let url = Bundle(for: BundleLocator.self)
                .url(forResource: "live-activity-content-v1", withExtension: "json")
        else {
            fatalError("live-activity-content-v1.json is missing from the test bundle")
        }
        do {
            return try JSONDecoder().decode(
                LiveActivityVectorFile.self, from: Data(contentsOf: url))
        } catch {
            fatalError("shared live-activity vectors failed to load: \(error)")
        }
    }()

    private final class BundleLocator {}
}
