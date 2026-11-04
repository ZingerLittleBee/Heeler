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
            /// Carried so the re-encoded snapshot the app decodes still holds
            /// herdr's rules, which the app ignores.
            let rules: [Rule]?
        }

        /// One herdr sidebar rule as the plugin exports it: only the fields
        /// the configuration gave.
        struct Rule: Codable, Sendable, Equatable {
            let equals: String?
            let contains: String?
            let startsWith: String?
            let gt: Double?
            let lt: Double?
            let ignoreCase: Bool?
            let fg: String?
            let bold: Bool?
            let dim: Bool?
            let hide: Bool?

            enum CodingKeys: String, CodingKey {
                case equals, contains, gt, lt, fg, bold, dim, hide
                case startsWith = "starts_with"
                case ignoreCase = "ignore_case"
            }
        }

        func jsonData() throws -> Data {
            try JSONEncoder().encode(self)
        }
    }

    static let shared: SidebarLayoutVectorFile = {
        do {
            return try JSONDecoder().decode(SidebarLayoutVectorFile.self, from: fileData())
        } catch {
            fatalError("shared sidebar layout vectors failed to load: \(error)")
        }
    }()

    /// The bundled vector file as the plugin repository holds it.
    static func fileData() throws -> Data {
        guard
            let url = Bundle(for: BundleLocator.self)
                .url(forResource: "sidebar-layout-v1", withExtension: "json")
        else {
            throw CocoaError(
                .fileNoSuchFile, userInfo: [NSFilePathErrorKey: "sidebar-layout-v1.json"])
        }
        return try Data(contentsOf: url)
    }

    private final class BundleLocator {}
}
