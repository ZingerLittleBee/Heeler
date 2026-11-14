import Foundation
import Testing

@testable import Heeler

@Suite("Live Activity Host publisher")
@MainActor
struct LiveActivityHostPublisherTests {
    private func temporaryStore() throws -> LiveActivityHostSnapshotStore {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-host-publisher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        return LiveActivityHostSnapshotStore(containerURL: container)
    }

    @Test func publishesInitialCatalogInOrderWithDisplayNames() throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.containerURL!) }
        let publisher = LiveActivityHostPublisher(store: store)
        let named = Host(name: "  My Mac  ", address: "mac.local", username: "me")
        let unnamed = Host(address: "server.local", username: "builder")

        publisher.publish([named, unnamed])

        #expect(store.read() == LiveActivityHostSnapshot(v: 1, hosts: [
            .init(id: named.id.uuidString, name: "My Mac", label: "M"),
            .init(id: unnamed.id.uuidString, name: "builder@server.local", label: "B"),
        ]))
    }

    @Test func publishesLabelsAcrossTheWholeCatalog() throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.containerURL!) }
        let publisher = LiveActivityHostPublisher(store: store)
        let laptop = Host(name: "Laptop", address: "laptop.local", username: "me")
        let oak = Host(name: "oak4d", address: "oak.local", username: "me")
        let macBook = Host(name: "MacBook", address: "macbook.local", username: "me")
        let macMini = Host(name: "Mac mini", address: "mini.local", username: "me")

        publisher.publish([laptop])
        #expect(store.read()?.hosts == [
            .init(id: laptop.id.uuidString, name: "Laptop", label: "L"),
        ])

        publisher.publish([laptop, oak, macBook, macMini])

        #expect(store.read()?.hosts.map(\.label) == ["L", "O", "MB", "Mm"])

        publisher.publish([macBook])
        #expect(store.read()?.hosts.map(\.label) == ["M"])
    }

    @Test func publishesRenamesAdditionsRemovalsAndOrder() throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.containerURL!) }
        let publisher = LiveActivityHostPublisher(store: store)
        var first = Host(name: "Old name", address: "mac.local", username: "me")
        let second = Host(name: "Server", address: "server.local", username: "me")
        publisher.publish([first])

        first.name = "New name"
        publisher.publish([first])
        #expect(store.read()?.hosts == [.init(id: first.id.uuidString, name: "New name", label: "N")])

        publisher.publish([first, second])
        #expect(store.read()?.hosts == [
            .init(id: first.id.uuidString, name: "New name", label: "N"),
            .init(id: second.id.uuidString, name: "Server", label: "S"),
        ])

        publisher.publish([second, first])
        #expect(store.read()?.hosts.map(\.id) == [second.id.uuidString, first.id.uuidString])

        publisher.publish([second])
        #expect(store.read()?.hosts == [.init(id: second.id.uuidString, name: "Server", label: "S")])

        publisher.publish([])
        #expect(store.read()?.hosts == [])
    }

    @Test func appPublishesBeforeStartAndObservesCatalogEdits() async throws {
        let store = try temporaryStore()
        let container = try #require(store.containerURL)
        defer { try? FileManager.default.removeItem(at: container) }
        var host = Host(name: "Original", address: "mac.local", username: "me")
        let hostStore = HostStore(volatileHosts: [host])
        let console = ConsoleStore { _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { ScriptedTransport(snapshot: .fixture()) }, keepalive: nil)
        }
        defer { console.setHosts([]) }
        let app = HeelerAppModel(
            pushRegistration: PushRegistrationStore(
                client: ScriptedPushRegistrationClient(), environment: .sandbox),
            sceneDirectory: AgentSceneDirectory(), hostStore: hostStore, console: console,
            liveActivityHosts: LiveActivityHostPublisher(store: store))

        #expect(store.read()?.hosts == [.init(id: host.id.uuidString, name: "Original", label: "O")])
        app.start()
        host.name = "Renamed"
        try hostStore.update(host)
        try await waitForHosts([.init(id: host.id.uuidString, name: "Renamed", label: "R")], in: store)

        let second = Host(name: "Server", address: "server.local", username: "me")
        try hostStore.add(second)
        try await waitForHosts([
            .init(id: host.id.uuidString, name: "Renamed", label: "R"),
            .init(id: second.id.uuidString, name: "Server", label: "S"),
        ], in: store)

        try hostStore.remove(host.id)
        try await waitForHosts([.init(id: second.id.uuidString, name: "Server", label: "S")], in: store)
    }

    private func waitForHosts(
        _ expected: [LiveActivityHostSnapshot.Entry], in store: LiveActivityHostSnapshotStore
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while store.read()?.hosts != expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.read()?.hosts == expected)
    }

    @Test func suppressesUnchangedWritesIncludingOnRelaunch() throws {
        let store = try temporaryStore()
        let container = try #require(store.containerURL)
        defer { try? FileManager.default.removeItem(at: container) }
        let publisher = LiveActivityHostPublisher(store: store)
        var host = Host(name: "My Mac", address: "mac.local", username: "me")
        publisher.publish([host])
        let url = container.appendingPathComponent("live-activity-hosts.json")
        let savedDate = Date(timeIntervalSince1970: 123456789)
        try FileManager.default.setAttributes([.modificationDate: savedDate], ofItemAtPath: url.path)

        host.username = "another-user"
        publisher.publish([host])
        LiveActivityHostPublisher(store: store).publish([host])

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attributes[.modificationDate] as? Date == savedDate)
        #expect(store.read()?.hosts == [.init(id: host.id.uuidString, name: "My Mac", label: "M")])
    }
}
