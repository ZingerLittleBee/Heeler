import Foundation

@MainActor
final class LiveActivityHostPublisher {
    private let store: LiveActivityHostSnapshotStore
    private lazy var published: LiveActivityHostSnapshot? = store.read()

    init(store: LiveActivityHostSnapshotStore = LiveActivityHostSnapshotStore()) {
        self.store = store
    }

    func publish(_ hosts: [Host]) {
        let catalog = hosts.map { (id: $0.id.uuidString, name: $0.displayName) }
        let labels = HostMonogram.labels(for: catalog)
        let snapshot = LiveActivityHostSnapshot(
            v: LiveActivityHostSnapshot.currentVersion,
            hosts: catalog.map { entry in
                .init(id: entry.id, name: entry.name, label: labels[entry.id])
            })
        guard snapshot != published else { return }
        published = snapshot
        store.write(snapshot)
    }
}
