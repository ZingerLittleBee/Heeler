import Foundation

@MainActor
final class LiveActivityHostPublisher {
    private let store: LiveActivityHostSnapshotStore
    private lazy var published: LiveActivityHostSnapshot? = store.read()

    init(store: LiveActivityHostSnapshotStore = LiveActivityHostSnapshotStore()) {
        self.store = store
    }

    func publish(_ hosts: [Host]) {
        let snapshot = LiveActivityHostSnapshot(
            v: LiveActivityHostSnapshot.currentVersion,
            hosts: hosts.map { .init(id: $0.id.uuidString, name: $0.displayName) })
        guard snapshot != published else { return }
        published = snapshot
        store.write(snapshot)
    }
}
