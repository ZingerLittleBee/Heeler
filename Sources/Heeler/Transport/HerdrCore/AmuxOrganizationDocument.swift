import Foundation

/// amux organization v1, read-only. Core's CAS version is not the schema version.
/// Membership is explicit and scoped to the connected core, never inferred from
/// a Terminal's directory, labels or parent. See docs/guides/amux-organization.md.
struct AmuxOrganizationDocument: Decodable, Equatable, Sendable {
    static let name = "amux-organization"

    struct Space: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let name: String
        let path: String
        let worktrees: [Worktree]

        func workspaceID(coreID: String) -> String { "amux-space-\(coreID.utf8.count):\(coreID)\(id)" }
    }

    struct Worktree: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let name: String
        let path: String
        let tabs: [Tab]

        func workspaceID(coreID: String) -> String { "amux-worktree-\(coreID.utf8.count):\(coreID)\(id)" }
    }

    struct Tab: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let name: String
        let terminals: [String]

        var tabID: String { "amux-tab-\(id)" }
    }

    let schemaVersion: Int
    let coreID: String
    let spaces: [Space]

    init?(value: JSONValue, connectedCoreID: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let bytes = try? encoder.encode(value), bytes.count <= 1_048_576,
            let decoded = try? JSONDecoder().decode(Self.self, from: bytes),
            decoded.schemaVersion == 1, decoded.coreID == connectedCoreID
        else { return nil }
        var spaces: Set<String> = []
        var worktrees: Set<String> = []
        var tabs: Set<String> = []
        var terminals: Set<String> = []
        for space in decoded.spaces {
            guard !space.id.isEmpty, spaces.insert(space.id).inserted, Self.isPath(space.path) else { return nil }
            for worktree in space.worktrees {
                guard !worktree.id.isEmpty, worktrees.insert(worktree.id).inserted,
                    Self.isPath(worktree.path)
                else { return nil }
                for tab in worktree.tabs {
                    guard !tab.id.isEmpty, tabs.insert(tab.id).inserted else { return nil }
                    for address in tab.terminals {
                        guard !address.isEmpty, !address.contains("/"), terminals.insert(address).inserted
                        else { return nil }
                    }
                }
            }
        }
        self = decoded
    }

    /// Paths are JSON values, not shell fragments. POSIX quotes and Unicode are
    /// valid here; the Core launch receives the original absolute Host path.
    private static func isPath(_ path: String) -> Bool {
        !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            && (path.hasPrefix("/") || RemoteHostPath.isWindowsAbsolute(path))
    }

    func directory(ofWorkspace id: String) -> String? {
        for space in spaces {
            if space.workspaceID(coreID: coreID) == id { return space.path }
            if let worktree = space.worktrees.first(where: { $0.workspaceID(coreID: coreID) == id }) {
                return worktree.path
            }
        }
        return nil
    }

    static func isWorkspace(_ id: String) -> Bool {
        id.hasPrefix("amux-space-") || id.hasPrefix("amux-worktree-")
    }
}

extension HerdrCoreTransport {
    func readAmuxOrganization(connectedCoreID: String) async throws -> (AmuxOrganizationDocument?, Int) {
        let result = try await call(
            "doc.get", params: .object(["name": .string(AmuxOrganizationDocument.name)]), isMutation: false)
        guard let version = HerdrCoreWire.integer(result["version"]), version >= 0 else {
            throw TransportError.malformedResponse(String(localized: "herdr-core: A document read has no version."))
        }
        return (result["value"].flatMap { AmuxOrganizationDocument(value: $0, connectedCoreID: connectedCoreID) }, version)
    }
}
