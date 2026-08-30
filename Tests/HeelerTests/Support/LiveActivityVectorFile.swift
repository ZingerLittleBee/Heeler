import Foundation

/// The shared Live Activity content envelope v1 vectors from
/// `plugin/test-vectors/`, the single source of truth for the encrypted
/// per-Host agent details across the Node plugin and this app. The JSON
/// file is bundled into the test target as a resource so both suites
/// exercise the same cases.
///
/// Payloads that stand in for a herdr pane use the observed `w…:p…` family
/// (uppercase included). Pin-order inventory ids such as `w1:p-work` stay
/// deliberately fake: those cases only need distinct opaque strings.
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
        /// Most-recently-pinned first. Present on pin-order vectors.
        let pinnedPaneIDs: [String]
        /// Full eligible inventory counts when the vector pins the sort rule.
        let counts: Counts?
        /// Herdr `agent list` shape used to drive the shared sort rule.
        let inventory: [InventoryAgent]
        var description: String { name }

        enum CodingKeys: String, CodingKey {
            case name, key, keyId, envelope, payload, decodeOnly
            case pinnedPaneIDs = "pinned_pane_ids"
            case counts, inventory
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            key = try container.decode(String.self, forKey: .key)
            keyId = try container.decode(String.self, forKey: .keyId)
            envelope = try container.decode(String.self, forKey: .envelope)
            payload = try container.decode(Payload.self, forKey: .payload)
            decodeOnly = try container.decodeIfPresent(Bool.self, forKey: .decodeOnly) ?? false
            pinnedPaneIDs = try container.decodeIfPresent([String].self, forKey: .pinnedPaneIDs) ?? []
            counts = try container.decodeIfPresent(Counts.self, forKey: .counts)
            inventory = try container.decodeIfPresent([InventoryAgent].self, forKey: .inventory) ?? []
        }
    }

    struct Counts: Decodable, Sendable {
        let working: Int
        let blocked: Int
        let done: Int
    }

    struct InventoryAgent: Decodable, Sendable {
        let paneID: String
        let agentStatus: String
        let agent: String?
        let name: String?
        let displayAgent: String?
        let terminalTitle: String?
        let terminalTitleStripped: String?

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case agentStatus = "agent_status"
            case agent, name
            case displayAgent = "display_agent"
            case terminalTitle = "terminal_title"
            case terminalTitleStripped = "terminal_title_stripped"
        }
    }

    struct Payload: Decodable, Sendable {
        let host: String
        let agents: [Agent]
    }

    struct Agent: Decodable, Sendable {
        let pane: String
        let kind: String
        let name: String?
        let status: String
        let title: String?
        let workspace: String?
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
