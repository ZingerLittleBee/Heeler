import Foundation
import Testing

@testable import Heeler

/// Decoder tests for the sidebar layout snapshot v1 (#281), driven by the
/// shared vectors in `plugin/test-vectors/sidebar-layout-v1.json` — the same
/// file the Node plugin tests consume, so the two implementations cannot
/// drift. Swift asserts decoded layout, tokens, styles, sort, and
/// diagnostics; it does not parse TOML.
@Suite("Sidebar layout snapshot")
struct SidebarLayoutVectorTests {
    private static let vectors = SidebarLayoutVectorFile.shared
    private static let diagnosticCategories: Set<String> = [
        "parse_error", "invalid_token", "invalid_schema", "read_error",
    ]
    private static let defaultTokenNames = [
        ["state_icon", "workspace", "tab"], ["agent"],
    ]

    /// Guards against silently loading an empty or truncated vector file;
    /// mirrors the same assertion in the Node suite.
    @Test func sharedVectorFileHasCases() {
        #expect(Self.vectors.valid.count >= 12)
        #expect(Self.vectors.invalid.count >= 37)
        #expect(Set(Self.vectors.valid.map(\.name)).count == Self.vectors.valid.count)
        #expect(Set(Self.vectors.invalid.map(\.name)).count == Self.vectors.invalid.count)
        #expect(Self.vectors.valid.allSatisfy { $0.snapshot.v == 1 })
        #expect(Self.vectors.invalid.allSatisfy { $0.snapshot.v == 1 })
        #expect(Self.vectors.valid.allSatisfy { $0.snapshot.diagnostics.isEmpty })
        #expect(Self.vectors.invalid.allSatisfy { $0.snapshot.diagnostics == [$0.error] })
        #expect(
            Set(Self.vectors.invalid.map(\.error)).isSuperset(of: [
                "parse_error", "invalid_token", "invalid_schema",
            ]))
    }

    @Test(arguments: vectors.valid)
    func decodesValidVector(vector: SidebarLayoutVectorFile.Valid) throws {
        let snapshot = try #require(
            AgentRowLayoutSnapshot.decode(try vector.snapshot.jsonData()))
        let expected = try layout(from: vector.snapshot)
        let expectedSort = try sort(vector.snapshot.agentPanelSort)

        #expect(snapshot.layout == expected)
        #expect(snapshot.agentPanelSort == expectedSort)
        #expect(snapshot.diagnostics == [])
        #expect(snapshot.layout.rowGap == vector.snapshot.sidebar.agents.rowGap)
        expectTokens(snapshot.layout.rows, match: vector.snapshot.sidebar.agents.rows)
        #expect(
            Set(snapshot.layout.rowsByAgent.keys)
                == Set(vector.snapshot.sidebar.agents.rowsByAgent.keys))
        for (kind, rows) in vector.snapshot.sidebar.agents.rowsByAgent {
            expectTokens(try #require(snapshot.layout.rowsByAgent[kind]), match: rows)
        }
    }

    /// Invalid vectors encode the plugin's rejected-TOML contract: a complete
    /// default layout/sort plus one diagnostic category. Their snapshots are
    /// valid JSON for `AgentRowLayoutSnapshot.decode`, not decode failures.
    @Test(arguments: vectors.invalid)
    func invalidVectorUsesFallbackSnapshot(vector: SidebarLayoutVectorFile.Invalid) throws {
        #expect(!vector.toml.isEmpty)
        #expect(Self.diagnosticCategories.contains(vector.error), "\(vector.name)")
        #expect(vector.snapshot.diagnostics == [vector.error])
        #expect(vector.snapshot.agentPanelSort == "spaces")
        #expect(vector.snapshot.sidebar.agents.rowGap == 0)
        #expect(vector.snapshot.sidebar.agents.rowsByAgent.isEmpty)
        #expect(
            vector.snapshot.sidebar.agents.rows.map { $0.map(\.token) }
                == Self.defaultTokenNames)

        let snapshot = try #require(
            AgentRowLayoutSnapshot.decode(try vector.snapshot.jsonData()))
        #expect(snapshot.layout == .heelerDefault)
        #expect(snapshot.agentPanelSort == .spaces)
        #expect(snapshot.diagnostics == [vector.error])
        #expect(snapshot.layout.rowGap == 0)
        #expect(snapshot.layout.rowsByAgent.isEmpty)
        expectTokens(snapshot.layout.rows, match: vector.snapshot.sidebar.agents.rows)
        #expect(
            snapshot.layout.rows.map { $0.map(\.token) }
                == [[.stateIcon, .workspace, .tab], [.agent]])
    }

    private func layout(from snapshot: SidebarLayoutVectorFile.Snapshot) throws -> AgentRowLayout {
        func row(_ tokens: [SidebarLayoutVectorFile.Snapshot.Token]) throws -> AgentRow {
            try tokens.map { token in
                let name = try #require(
                    AgentRowToken(rawValue: token.token),
                    Comment(rawValue: token.token))
                return AgentRowStyledToken(
                    name, fg: token.fg.flatMap(HexColor.init), bold: token.bold, dim: token.dim)
            }
        }
        return AgentRowLayout(
            rows: try snapshot.sidebar.agents.rows.map(row),
            rowGap: snapshot.sidebar.agents.rowGap,
            rowsByAgent: try snapshot.sidebar.agents.rowsByAgent.mapValues { try $0.map(row) })
    }

    private func sort(_ raw: String) throws -> AgentPanelSort {
        let normalized = raw == "workspaces" ? "spaces" : raw
        return try #require(AgentPanelSort(rawValue: normalized), "sort \(raw)")
    }

    private func expectTokens(
        _ actual: [AgentRow],
        match expected: [[SidebarLayoutVectorFile.Snapshot.Token]]
    ) {
        #expect(actual.map { $0.map(\.token.rawValue) } == expected.map { $0.map(\.token) })
        #expect(actual.map { $0.map(\.fg?.rawValue) } == expected.map { $0.map(\.fg) })
        #expect(actual.map { $0.map(\.bold) } == expected.map { $0.map(\.bold) })
        #expect(actual.map { $0.map(\.dim) } == expected.map { $0.map(\.dim) })
    }
}
