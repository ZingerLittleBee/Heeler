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

    @Test func hostLayoutsPersistWithoutCrossHostChanges() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let first = UUID(), second = UUID(), third = UUID()
        let custom = AgentRowLayout(rows: [[.init(.terminalTitle, fg: HexColor("#abc"), bold: false)]],
                                    rowGap: 2, rowsByAgent: ["claude": [[.init(.custom("pin_icon"))]]])
        let plugin = AgentRowLayoutSnapshot(layout: AgentRowLayout(rows: [[.init(.agent)]]))
        let store = AgentRowLayoutStore(defaults: defaults)
        #expect(store.hostLayouts.isEmpty && store.catalogLoadError == nil)
        try store.setLayout(custom, for: first)
        try store.setLayout(AgentRowLayout(rows: []), for: second)

        let reloaded = AgentRowLayoutStore(defaults: defaults)
        #expect(reloaded.hostLayouts == [first: custom, second: AgentRowLayout(rows: [])])
        #expect(reloaded.resolvedLayout(for: first, pluginSnapshot: plugin) == custom)
        #expect(reloaded.resolvedLayout(for: second, pluginSnapshot: plugin).rows.isEmpty)
        #expect(reloaded.resolvedLayout(for: third, pluginSnapshot: plugin) == plugin.layout)
        #expect(reloaded.resolvedLayout(for: third, pluginSnapshot: nil) == .heelerDefault)
        #expect(reloaded.catalogLoadError == nil)
    }

    @Test func batchWritesAreAtomicAndNilRestoresInheritance() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = UUID(), other = UUID()
        let custom = AgentRowLayout(rows: [[.init(.pane)]])
        let plugin = AgentRowLayoutSnapshot(layout: AgentRowLayout(rows: [[.init(.agent)]]))
        let store = AgentRowLayoutStore(defaults: defaults)
        try store.setLayouts([host: AgentRowLayout(rows: []), other: custom])
        let before = defaults.data(forKey: "agent-row-layouts")
        #expect(throws: AgentRowLayoutError.invalidRowGap) {
            try store.setLayouts([host: nil, other: AgentRowLayout(rows: [], rowGap: -1)])
        }
        #expect(store.hostLayouts == [host: AgentRowLayout(rows: []), other: custom])
        #expect(defaults.data(forKey: "agent-row-layouts") == before)
        try store.setLayouts([host: nil])
        #expect(store.resolvedLayout(for: host, pluginSnapshot: plugin) == plugin.layout)
        let reloaded = AgentRowLayoutStore(defaults: defaults)
        #expect(reloaded.hostLayouts == [other: custom])
        #expect(reloaded.resolvedLayout(for: host, pluginSnapshot: nil) == .heelerDefault)
    }

    @Test func legacyGlobalLayoutIsIgnoredAndDroppedOnNextWrite() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = UUID()
        let custom = AgentRowLayout(rows: [[.init(.pane)]])
        let plugin = AgentRowLayoutSnapshot(layout: AgentRowLayout(rows: [[.init(.agent)]]))
        let legacy = Data(#"{"version":1,"hostLayouts":[],"globalLayout":{"rows":[[{"token":"workspace"}]],"rowGap":0,"rowsByAgent":{}}}"#.utf8)
        defaults.set(legacy, forKey: "agent-row-layouts")
        let store = AgentRowLayoutStore(defaults: defaults)
        #expect(store.catalogLoadError == nil)
        #expect(store.resolvedLayout(for: host, pluginSnapshot: plugin) == plugin.layout)
        #expect(store.resolvedLayout(for: host, pluginSnapshot: nil) == .heelerDefault)
        try store.setLayout(custom, for: host)
        let data = try #require(defaults.data(forKey: "agent-row-layouts"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["globalLayout"] == nil)
        #expect(AgentRowLayoutStore(defaults: defaults).hostLayouts == [host: custom])
    }

    @Test func unreadableOrFutureCatalogRefusesWritesAndRetainsBytes() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        for json in ["not json", #"{"version":2,"hostLayouts":[]}"#,
                     #"{"version":1,"hostLayouts":["\#(UUID().uuidString)",{"rows":[[{"token":"future"}]],"rowGap":0,"rowsByAgent":{}}]}"#] {
            let corrupt = Data(json.utf8)
            defaults.set(corrupt, forKey: "agent-row-layouts")
            let store = AgentRowLayoutStore(defaults: defaults)
            #expect(store.catalogLoadError == .catalogUnreadable)
            #expect(throws: AgentRowLayoutStoreError.catalogUnreadable) {
                try store.setLayout(.heelerDefault, for: UUID())
            }
            #expect(throws: AgentRowLayoutStoreError.catalogUnreadable) {
                try store.setLayouts([UUID(): nil])
            }
            #expect(defaults.data(forKey: "agent-row-layouts") == corrupt)
        }
    }

    @Test func invalidEditsDoNotChangeMemoryOrPersistedCatalog() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = AgentRowLayoutStore(defaults: defaults)
        let host = UUID()
        try store.setLayout(.heelerDefault, for: host)
        let before = defaults.data(forKey: "agent-row-layouts")
        #expect(throws: AgentRowLayoutError.invalidRowGap) {
            try store.setLayout(AgentRowLayout(rows: [], rowGap: -1), for: host)
        }
        #expect(throws: AgentRowLayoutError.tooManyRows) {
            try store.setLayout(AgentRowLayout(rows: Array(repeating: [], count: 17)), for: UUID())
        }
        #expect(store.hostLayouts == [host: .heelerDefault])
        #expect(defaults.data(forKey: "agent-row-layouts") == before)
    }
}
