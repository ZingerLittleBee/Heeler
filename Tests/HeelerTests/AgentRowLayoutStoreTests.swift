import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Agent row layout store")
struct AgentRowLayoutStoreTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-agent-row-layout-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func globalAndHostLayoutsPersistWithoutCrossHostChanges() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let first = UUID(), second = UUID(), third = UUID()
        let global = AgentRowLayout(rows: [[.init(.workspace)]])
        let custom = AgentRowLayout(rows: [[.init(.terminalTitle, fg: HexColor("#abc"), bold: false)]],
                                    rowGap: 2, rowsByAgent: ["claude": [[.init(.custom("pin_icon"))]]])
        let store = AgentRowLayoutStore(defaults: defaults)
        #expect(store.hostLayouts.isEmpty && store.globalLayout == nil && store.catalogLoadError == nil)
        try store.setGlobalLayout(global)
        try store.setLayout(custom, for: first)
        try store.setLayout(AgentRowLayout(rows: []), for: second)

        let reloaded = AgentRowLayoutStore(defaults: defaults)
        #expect(reloaded.hostLayouts == [first: custom, second: AgentRowLayout(rows: [])])
        #expect(reloaded.globalLayout == global)
        #expect(reloaded.resolvedLayout(for: first, pluginSnapshot: nil) == custom)
        #expect(reloaded.resolvedLayout(for: third, pluginSnapshot: nil) == global)
        #expect(reloaded.catalogLoadError == nil)
    }

    @Test func clearingOverridesRestoresInheritanceAcrossReloads() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = UUID(), other = UUID()
        let custom = AgentRowLayout(rows: [[.init(.pane)]])
        let plugin = AgentRowLayoutSnapshot(layout: AgentRowLayout(rows: [[.init(.agent)]]))
        let store = AgentRowLayoutStore(defaults: defaults)
        try store.setGlobalLayout(custom)
        try store.setLayout(AgentRowLayout(rows: []), for: host)
        try store.setLayout(custom, for: other)
        try store.setLayout(nil, for: host)
        #expect(store.resolvedLayout(for: host, pluginSnapshot: plugin) == custom)
        try store.setGlobalLayout(nil)
        let reloaded = AgentRowLayoutStore(defaults: defaults)
        #expect(reloaded.resolvedLayout(for: host, pluginSnapshot: plugin) == plugin.layout)
        #expect(reloaded.resolvedLayout(for: host, pluginSnapshot: nil) == .heelerDefault)
        #expect(reloaded.hostLayouts == [other: custom])
    }

    @Test func unreadableOrFutureCatalogRefusesWritesAndRetainsBytes() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        for json in ["not json", #"{"version":2,"hostLayouts":[],"globalLayout":null}"#,
                     #"{"version":1,"hostLayouts":[],"globalLayout":{"rows":[[{"token":"future"}]]}}"#] {
            let corrupt = Data(json.utf8)
            defaults.set(corrupt, forKey: "agent-row-layouts")
            let store = AgentRowLayoutStore(defaults: defaults)
            #expect(store.catalogLoadError == .catalogUnreadable)
            #expect(throws: AgentRowLayoutStoreError.catalogUnreadable) {
                try store.setGlobalLayout(.heelerDefault)
            }
            #expect(throws: AgentRowLayoutStoreError.catalogUnreadable) {
                try store.setLayout(nil, for: UUID())
            }
            #expect(defaults.data(forKey: "agent-row-layouts") == corrupt)
        }
    }

    @Test func invalidEditsDoNotChangeMemoryOrPersistedCatalog() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = AgentRowLayoutStore(defaults: defaults)
        let host = UUID()
        try store.setGlobalLayout(.heelerDefault)
        let before = defaults.data(forKey: "agent-row-layouts")
        #expect(throws: AgentRowLayoutError.invalidRowGap) {
            try store.setLayout(AgentRowLayout(rows: [], rowGap: -1), for: host)
        }
        #expect(throws: AgentRowLayoutError.tooManyRows) {
            try store.setGlobalLayout(AgentRowLayout(rows: Array(repeating: [], count: 17)))
        }
        #expect(store.hostLayouts.isEmpty && store.globalLayout == .heelerDefault)
        #expect(defaults.data(forKey: "agent-row-layouts") == before)
    }
}
