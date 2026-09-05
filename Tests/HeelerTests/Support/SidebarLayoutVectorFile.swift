import Foundation

/// The shared sidebar layout snapshot v1 vectors from `plugin/test-vectors/`,
/// the single source of truth for the plugin-normalized `sidebar.json` across
/// the Node parser and this app. The JSON file is bundled into the test
/// target as a resource so both suites exercise the same cases.
///
/// Each entry carries the plugin's TOML input and its complete expected
/// snapshot. Swift consumes the snapshots through
/// `AgentRowLayoutSnapshot.decode` and does not parse TOML. Invalid entries
/// are rejected TOML, not invalid JSON: their snapshots are the complete
/// default layout/sort plus a diagnostic category.
struct SidebarLayoutVectorFile: Decodable, Sendable {
    let valid: [Valid]
    let invalid: [Invalid]

    struct Valid: Decodable, Sendable, CustomStringConvertible {
        let name: String
        /// Plugin input only. Never passed to the Swift snapshot decoder.
        let toml: String
        let snapshot: Snapshot
        var description: String { name }
    }

    struct Invalid: Decodable, Sendable, CustomStringConvertible {
        let name: String
        /// The rejected TOML. Swift does not parse it.
        let toml: String
        /// Expected diagnostic category, e.g. "parse_error".
        let error: String
        let snapshot: Snapshot
        var description: String { name }
    }

    /// Structured snapshot JSON as written to `sidebar.json`. Re-encoded
    /// bytes are what `AgentRowLayoutSnapshot.decode` consumes.
    struct Snapshot: Codable, Sendable {
        let v: Int
        let generatedAt: Int
        let source: Source
        let agentPanelSort: String
        let sidebar: Sidebar
        let diagnostics: [String]

        enum CodingKeys: String, CodingKey {
            case v, source, sidebar, diagnostics
            case generatedAt = "generated_at"
            case agentPanelSort = "agent_panel_sort"
        }

        struct Source: Codable, Sendable {
            let path: String
            let found: Bool
            let mtimeMs: Double?

            enum CodingKeys: String, CodingKey {
                case path, found
                case mtimeMs = "mtime_ms"
            }
        }

        struct Sidebar: Codable, Sendable {
            let agents: Agents
        }

        struct Agents: Codable, Sendable {
            let rowGap: Int
            let rows: [[Token]]
            let rowsByAgent: [String: [[Token]]]

            enum CodingKeys: String, CodingKey {
                case rowGap = "row_gap"
                case rows
                case rowsByAgent = "rows_by_agent"
            }
        }

        struct Token: Codable, Sendable, Equatable {
            let token: String
            let fg: String?
            let bold: Bool?
            let dim: Bool?
        }

        func jsonData() throws -> Data {
            try JSONEncoder().encode(self)
        }
    }

    static let shared: SidebarLayoutVectorFile = {
        guard
            let url = Bundle(for: BundleLocator.self)
                .url(forResource: "sidebar-layout-v1", withExtension: "json")
        else {
            fatalError("sidebar-layout-v1.json is missing from the test bundle")
        }
        do {
            return try JSONDecoder().decode(
                SidebarLayoutVectorFile.self, from: Data(contentsOf: url))
        } catch {
            fatalError("shared sidebar layout vectors failed to load: \(error)")
        }
    }()

    private final class BundleLocator {}
}
