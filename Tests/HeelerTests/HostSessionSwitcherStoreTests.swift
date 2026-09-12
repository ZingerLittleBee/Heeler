import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Host session switcher store")
struct HostSessionSwitcherStoreTests {
    /// `nonisolated` so the `@Sendable` discovery closures below can read it.
    nonisolated private static let sessions = [
        HerdrSession(name: "default", isDefault: true, isRunning: true),
        HerdrSession(name: "work", isDefault: false, isRunning: true),
        HerdrSession(name: "stale", isDefault: false, isRunning: false),
    ]

    private static func host(named name: String) -> Host {
        var host = Host.fixture(name: name)
        host.address = "\(name).example.com"
        return host
    }

    private struct DiscoveryFailure: Error {}

    @Test("Only unselected running sessions can be chosen")
    func selectableSessions() {
        #expect(
            HerdrSessionSelection.isSelectable(
                Self.sessions[1], currentSessionName: ""))
        #expect(
            !HerdrSessionSelection.isSelectable(
                Self.sessions[1], currentSessionName: "work"))
        #expect(
            !HerdrSessionSelection.isSelectable(
                Self.sessions[2], currentSessionName: ""))
        // A stopped named session has no socket to reach, so it stays
        // unchosen whatever session is currently in effect.
        #expect(
            !HerdrSessionSelection.isSelectable(
                Self.sessions[2], currentSessionName: "work"))
        // The default session is always a way back.
        #expect(
            HerdrSessionSelection.isSelectable(
                Self.sessions[0], currentSessionName: "work"))
        #expect(HerdrSessionSelection.isSelected(Self.sessions[0], currentSessionName: ""))
        #expect(HerdrSessionSelection.isSelected(Self.sessions[1], currentSessionName: "work"))
        #expect(!HerdrSessionSelection.isSelected(Self.sessions[1], currentSessionName: "default"))
    }

    @Test("Discovery publishes each Host's own sessions")
    func discoveryIsPublishedPerHost() async {
        let first = Self.host(named: "alpha")
        let second = Self.host(named: "beta")
        let store = HostSessionSwitcherStore()

        await store.load(hosts: [first, second], using: { hostID in
            hostID == first.id ? [Self.sessions[1]] : [Self.sessions[0], Self.sessions[2]]
        })

        #expect(store.discoveries[first.id] == .available([Self.sessions[1]]))
        #expect(store.discoveries[second.id] == .available([Self.sessions[0], Self.sessions[2]]))
    }

    @Test("One Host's discovery failure leaves the other Host's sessions intact")
    func discoveryFailureIsPerHost() async {
        let healthy = Self.host(named: "alpha")
        let offline = Self.host(named: "beta")
        let store = HostSessionSwitcherStore()

        await store.load(hosts: [healthy, offline], using: { hostID in
            guard hostID == healthy.id else {
                throw TransportError.sshUnreachable(detail: "down")
            }
            return [Self.sessions[0]]
        })

        #expect(store.discoveries[healthy.id] == .available([Self.sessions[0]]))
        #expect(
            store.discoveries[offline.id]
                == .failed(TransportError.sshUnreachable(detail: "down").presentation.message))
    }

    @Test("A non-transport discovery failure falls back to a plain message")
    func discoveryFailureFallsBack() async {
        let host = Self.host(named: "alpha")
        let store = HostSessionSwitcherStore()

        await store.load(hosts: [host], using: { _ in throw DiscoveryFailure() })

        #expect(store.discoveries[host.id] == .failed("Could not discover this Host's sessions."))
    }

    @Test("Selecting a session persists it through the Host catalog")
    func selectionPersistsThroughTheCatalog() throws {
        let host = Self.host(named: "alpha")
        let catalog = HostStore(volatileHosts: [host])
        let store = HostSessionSwitcherStore()

        try store.select(Self.sessions[1], for: host.id, in: catalog)
        #expect(catalog.hosts.first?.sessionName == "work")

        try store.select(Self.sessions[0], for: host.id, in: catalog)
        #expect(catalog.hosts.first?.sessionName == "")
    }
}
