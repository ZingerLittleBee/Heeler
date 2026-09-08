import Foundation
import Testing

@testable import Heeler

/// The device-local per-pane name store (#290): names keyed by
/// `(hostID, paneID)`, versioned UserDefaults blob, trimmed writes.
@MainActor
@Suite("Pane name store")
struct PaneNameStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "pane-name-store-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func unsetNamesAreNil() {
        let store = PaneNameStore(defaults: makeDefaults())
        #expect(store.name(hostID: UUID(), paneID: "w1:p1") == nil)
    }

    @Test func setAndReadSurviveReload() {
        let defaults = makeDefaults()
        let hostID = UUID()
        PaneNameStore(defaults: defaults).set(
            "backend fix", hostID: hostID, paneID: "w1:p1")
        let reloaded = PaneNameStore(defaults: defaults)
        #expect(reloaded.name(hostID: hostID, paneID: "w1:p1") == "backend fix")
    }

    @Test func namesAreScopedToPaneAndHost() {
        let store = PaneNameStore(defaults: makeDefaults())
        let hostID = UUID()
        store.set("a", hostID: hostID, paneID: "w1:p1")
        store.set("b", hostID: hostID, paneID: "w1:p2")
        #expect(store.name(hostID: hostID, paneID: "w1:p1") == "a")
        #expect(store.name(hostID: hostID, paneID: "w1:p2") == "b")
        #expect(store.name(hostID: UUID(), paneID: "w1:p1") == nil)
    }

    @Test func emptyAndWhitespaceNamesClear() {
        let store = PaneNameStore(defaults: makeDefaults())
        let hostID = UUID()
        store.set("old", hostID: hostID, paneID: "w1:p1")
        store.set("   ", hostID: hostID, paneID: "w1:p1")
        #expect(store.name(hostID: hostID, paneID: "w1:p1") == nil)
    }

    @Test func namesAreTrimmed() {
        let store = PaneNameStore(defaults: makeDefaults())
        let hostID = UUID()
        store.set("  frontend  ", hostID: hostID, paneID: "w1:p1")
        #expect(store.name(hostID: hostID, paneID: "w1:p1") == "frontend")
    }
}