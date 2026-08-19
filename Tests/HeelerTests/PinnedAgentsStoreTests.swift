import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Pinned agents store")
struct PinnedAgentsStoreTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-pins-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func togglePersistsAcrossInstances() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hostID = UUID()

        let store = PinnedAgentsStore(defaults: defaults)
        store.togglePin(hostID: hostID, paneID: "w1:p1")
        store.togglePin(hostID: hostID, paneID: "w1:p2")
        #expect(store.revision == 2)

        let reloaded = PinnedAgentsStore(defaults: defaults)
        #expect(reloaded.pinnedPaneIDs(for: hostID) == ["w1:p2", "w1:p1"])
        #expect(reloaded.isPinned(hostID: hostID, paneID: "w1:p2"))
        #expect(reloaded.pinRank(hostID: hostID, paneID: "w1:p2") == 0)
        #expect(reloaded.pinRank(hostID: hostID, paneID: "w1:p1") == 1)
    }

    @Test func togglePinsThenUnpins() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hostID = UUID()
        let store = PinnedAgentsStore(defaults: defaults)

        #expect(!store.isPinned(hostID: hostID, paneID: "w1:p1"))
        #expect(store.pinRank(hostID: hostID, paneID: "w1:p1") == nil)

        store.togglePin(hostID: hostID, paneID: "w1:p1")
        #expect(store.isPinned(hostID: hostID, paneID: "w1:p1"))
        #expect(store.pinRank(hostID: hostID, paneID: "w1:p1") == 0)

        store.togglePin(hostID: hostID, paneID: "w1:p1")
        #expect(!store.isPinned(hostID: hostID, paneID: "w1:p1"))
        #expect(store.pinnedPaneIDs(for: hostID).isEmpty)
        #expect(PinnedAgentsStore(defaults: defaults).pinnedPaneIDs(for: hostID).isEmpty)
    }

    @Test func rePinMovesTheEntryToMostRecent() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hostID = UUID()
        let store = PinnedAgentsStore(defaults: defaults)

        store.togglePin(hostID: hostID, paneID: "w1:p1")
        store.togglePin(hostID: hostID, paneID: "w1:p2")
        #expect(store.pinnedPaneIDs(for: hostID) == ["w1:p2", "w1:p1"])

        // Unpin then pin again: the new pin is most-recent, ahead of p2.
        store.togglePin(hostID: hostID, paneID: "w1:p1")
        store.togglePin(hostID: hostID, paneID: "w1:p1")
        #expect(store.pinnedPaneIDs(for: hostID) == ["w1:p1", "w1:p2"])
        #expect(store.pinRank(hostID: hostID, paneID: "w1:p1") == 0)
        #expect(store.pinRank(hostID: hostID, paneID: "w1:p2") == 1)
    }

    @Test func pinsAreIsolatedPerHost() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hostA = UUID()
        let hostB = UUID()
        let store = PinnedAgentsStore(defaults: defaults)

        store.togglePin(hostID: hostA, paneID: "w1:p1")
        store.togglePin(hostID: hostB, paneID: "w1:p1")
        store.togglePin(hostID: hostB, paneID: "w2:p9")

        #expect(store.pinnedPaneIDs(for: hostA) == ["w1:p1"])
        #expect(store.pinnedPaneIDs(for: hostB) == ["w2:p9", "w1:p1"])
        #expect(store.pinRank(hostID: hostB, paneID: "w2:p9") == 0)
        #expect(store.pinRank(hostID: hostB, paneID: "w1:p1") == 1)
        #expect(store.pinRank(hostID: hostA, paneID: "w1:p1") == 2)
        #expect(!store.isPinned(hostID: hostA, paneID: "w2:p9"))
        #expect(store.pinnedPaneIDs(for: UUID()).isEmpty)
    }

    @Test func malformedDataStartsEmptyWithoutCrashing() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set(Data("not json".utf8), forKey: "pinned-agents")

        let store = PinnedAgentsStore(defaults: defaults)
        #expect(store.pinnedPaneIDs(for: UUID()).isEmpty)

        let hostID = UUID()
        store.togglePin(hostID: hostID, paneID: "w1:p1")
        #expect(store.isPinned(hostID: hostID, paneID: "w1:p1"))
        #expect(PinnedAgentsStore(defaults: defaults).isPinned(hostID: hostID, paneID: "w1:p1"))
    }

    @Test func unknownVersionStartsEmptyWithoutCrashing() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hostID = UUID()
        let blob: [String: Any] = [
            "version": 99,
            "entries": [
                ["hostID": hostID.uuidString, "paneID": "w1:p1"]
            ],
        ]
        defaults.set(
            try JSONSerialization.data(withJSONObject: blob), forKey: "pinned-agents")

        let store = PinnedAgentsStore(defaults: defaults)
        #expect(!store.isPinned(hostID: hostID, paneID: "w1:p1"))
        #expect(store.pinnedPaneIDs(for: hostID).isEmpty)
    }

    @Test func danglingEntriesAreRetainedUntilUnpinned() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hostID = UUID()
        let store = PinnedAgentsStore(defaults: defaults)
        store.togglePin(hostID: hostID, paneID: "gone:pane")

        // The store never sees a live Agent list, so a closed pane cannot
        // drop its pin. Reload keeps the dangling entry.
        let reloaded = PinnedAgentsStore(defaults: defaults)
        #expect(reloaded.isPinned(hostID: hostID, paneID: "gone:pane"))
        #expect(reloaded.pinnedPaneIDs(for: hostID) == ["gone:pane"])
        #expect(reloaded.pinRank(hostID: hostID, paneID: "gone:pane") == 0)
    }
}
