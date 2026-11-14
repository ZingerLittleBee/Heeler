import Foundation
import Testing

@testable import Heeler

@Suite("Live Activity Host snapshot")
struct LiveActivityHostSnapshotTests {
    private let snapshot = LiveActivityHostSnapshot(
        v: 1,
        hosts: [
            .init(id: "6D8EC348-4DAF-455C-BA8F-5FCC41799C0E", name: "My Mac", label: "MM"),
            .init(id: "80A74CCD-7998-4089-BADD-3A9AE9982FC4", name: "Build Server", label: "BS"),
        ])

    private func temporaryStore() throws -> LiveActivityHostSnapshotStore {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-hosts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        return LiveActivityHostSnapshotStore(containerURL: container)
    }

    @Test func roundTripsSnapshot() throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.containerURL!) }

        store.write(snapshot)

        #expect(store.read() == snapshot)
    }

    @Test func returnsNilWithoutAFile() throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.containerURL!) }

        #expect(store.read() == nil)
    }

    @Test func returnsNilWithoutAContainer() {
        let store = LiveActivityHostSnapshotStore(containerURL: nil)

        store.write(snapshot)

        #expect(store.read() == nil)
    }

    @Test(arguments: [
        "not JSON",
        #"{"v":1,"hosts":[{"id":"host","name":7}]}"#,
        #"{"v":1}"#,
        #"{"v":2,"hosts":[]}"#,
    ])
    func returnsNilForUnreadableSnapshots(_ json: String) throws {
        let store = try temporaryStore()
        let container = try #require(store.containerURL)
        defer { try? FileManager.default.removeItem(at: container) }
        try Data(json.utf8).write(to: container.appendingPathComponent("live-activity-hosts.json"))

        #expect(store.read() == nil)
    }

    @Test func ignoresFutureFields() throws {
        let store = try temporaryStore()
        let container = try #require(store.containerURL)
        defer { try? FileManager.default.removeItem(at: container) }
        let json = #"{"v":1,"hosts":[{"id":"host","name":"My Mac","label":"MM"}],"future":true}"#
        try Data(json.utf8).write(to: container.appendingPathComponent("live-activity-hosts.json"))

        #expect(store.read() == LiveActivityHostSnapshot(v: 1, hosts: [.init(id: "host", name: "My Mac", label: "MM")]))
    }

    @Test func decodesOlderEntriesWithoutLabels() throws {
        let store = try temporaryStore()
        let container = try #require(store.containerURL)
        defer { try? FileManager.default.removeItem(at: container) }
        let json = #"{"v":1,"hosts":[{"id":"host","name":"Laptop"}]}"#
        try Data(json.utf8).write(to: container.appendingPathComponent("live-activity-hosts.json"))

        #expect(store.read() == LiveActivityHostSnapshot(v: 1, hosts: [.init(id: "host", name: "Laptop")]))
    }

    @Test func looksUpNamesByHostID() {
        #expect(snapshot.name(forHostID: "6D8EC348-4DAF-455C-BA8F-5FCC41799C0E") == "My Mac")
        #expect(snapshot.name(forHostID: "80A74CCD-7998-4089-BADD-3A9AE9982FC4") == "Build Server")
        #expect(snapshot.name(forHostID: "unknown") == nil)
        #expect(snapshot.label(forHostID: "6D8EC348-4DAF-455C-BA8F-5FCC41799C0E") == "MM")
        #expect(snapshot.label(forHostID: "unknown") == nil)
    }
}
