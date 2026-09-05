import Foundation
import Observation
import Synchronization
import Testing

@testable import Heeler

@MainActor
@Suite("Herdr sidebar snapshots", .timeLimit(.minutes(1)))
struct HerdrSidebarSnapshotStoreTests {
    private let hostID = UUID()
    private let first = Data(#"{"v":1,"agent_panel_sort":"priority","sidebar":{"agents":{"rows":[[{"token":"terminal_title_stripped"}]]}}}"#.utf8)
    private let second = Data(#"{"v":1,"sidebar":{"agents":{"rows":[[{"token":"workspace"}]]}}}"#.utf8)

    @Test func readsExistingTransportAndPublishesMissingMalformedAndErrorFallbacks() async {
        let transport = ScriptedTransport()
        let provider = ScriptedTransportProvider(transports: [hostID: transport])
        let store = HerdrSidebarSnapshotStore()
        store.reconcile([hostID: .init(generation: 1, revision: 0)], transports: provider, didChange: {})
        await store.waitForPendingReads()
        #expect(store.states[hostID] == .loaded(nil))
        for data in [Data("invalid".utf8), Data(#"{"v":2}"#.utf8), first] {
            await transport.setSidebarLayout(data)
            await store.refresh(transports: provider, didChange: {})
            #expect(store.snapshot(for: hostID) == AgentRowLayoutSnapshot.decode(data))
        }
        await transport.setSidebarLayoutReadFailure(NotificationRegistrationError.pluginNotInstalled)
        await store.refresh(transports: provider, didChange: {})
        #expect(store.states[hostID] == .unavailable)
        #expect(store.snapshot(for: hostID) == nil)
        #expect(await transport.sidebarLayoutReads == 5)
        #expect(await transport.capturedSubscriptions.isEmpty)
        #expect(await transport.isClosed == false)
    }

    @Test func generationChangeRejectsAnOldReadEvenWhenItIgnoresCancellation() async {
        let transport = ScriptedTransport()
        await transport.setSidebarLayout(first)
        let provider = ScriptedTransportProvider(transports: [hostID: transport])
        let store = HerdrSidebarSnapshotStore()
        store.reconcile([hostID: .init(generation: 1, revision: 0)], transports: provider, didChange: {})
        await store.waitForPendingReads()
        let gate = ScriptedTransportCallGate()
        await transport.gateNextSidebarLayoutRead(gate)
        let oldRead = Task { await store.refresh(transports: provider, didChange: {}) }
        await gate.waitForEntry()
        await transport.setSidebarLayout(second)
        store.reconcile([hostID: .init(generation: 2, revision: 0)], transports: provider, didChange: {})
        #expect(store.states[hostID] == .loading)
        await store.waitForPendingReads()
        #expect(store.snapshot(for: hostID) == AgentRowLayoutSnapshot.decode(second))
        await gate.open()
        await oldRead.value
        #expect(store.snapshot(for: hostID) == AgentRowLayoutSnapshot.decode(second))
    }

    @Test func removedAndReaddedHostCannotReuseAnOldRequestIdentity() async {
        let transport = ScriptedTransport()
        await transport.setSidebarLayout(first)
        let provider = ScriptedTransportProvider(transports: [hostID: transport])
        let store = HerdrSidebarSnapshotStore()
        let connection: [Host.ID: HerdrSidebarSnapshotStore.Connection] = [hostID: .init(generation: 1, revision: 0)]
        store.reconcile(connection, transports: provider, didChange: {})
        await store.waitForPendingReads()
        let gate = ScriptedTransportCallGate()
        await transport.gateNextSidebarLayoutRead(gate)
        let oldRead = Task { await store.refresh(transports: provider, didChange: {}) }
        await gate.waitForEntry()
        store.reconcile([:], transports: provider, didChange: {})
        #expect(store.states.isEmpty)
        await transport.setSidebarLayout(second)
        store.reconcile(connection, transports: provider, didChange: {})
        await store.waitForPendingReads()
        await gate.open()
        await oldRead.value
        #expect(store.snapshot(for: hostID) == AgentRowLayoutSnapshot.decode(second))
    }

    @Test func unchangedProjectionDoesNotReadAgainAndRevisionPublishesObservably() async {
        let transport = ScriptedTransport()
        let provider = ScriptedTransportProvider(transports: [hostID: transport])
        let store = HerdrSidebarSnapshotStore()
        let connection: [Host.ID: HerdrSidebarSnapshotStore.Connection] = [hostID: .init(generation: 1, revision: 0)]
        store.reconcile(connection, transports: provider, didChange: {})
        await store.waitForPendingReads()
        store.reconcile(connection, transports: provider, didChange: {})
        await store.waitForPendingReads()
        #expect(await transport.sidebarLayoutReads == 1)
        let changed = Mutex(false)
        withObservationTracking {
            _ = store.snapshot(for: hostID)
        } onChange: {
            changed.withLock { $0 = true }
        }
        await transport.setSidebarLayout(first)
        store.reconcile([hostID: .init(generation: 1, revision: 1)], transports: provider, didChange: {})
        await store.waitForPendingReads()
        #expect(changed.withLock { $0 })
        #expect(store.snapshot(for: hostID) == AgentRowLayoutSnapshot.decode(first))
    }
}
