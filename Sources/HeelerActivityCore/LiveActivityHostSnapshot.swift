import Foundation

struct LiveActivityHostSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var v: Int
    var hosts: [Entry]

    struct Entry: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var label: String?

        init(id: String, name: String, label: String? = nil) {
            self.id = id
            self.name = name
            self.label = label
        }
    }

    func name(forHostID hostID: String) -> String? {
        hosts.first { $0.id == hostID }?.name
    }

    func label(forHostID hostID: String) -> String? {
        hosts.first { $0.id == hostID }?.label
    }
}

struct LiveActivityHostSnapshotStore: Sendable {
    var containerURL: URL? = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: NotificationKeyStore.sharedAccessGroup)

    private var fileURL: URL? {
        containerURL?.appendingPathComponent("live-activity-hosts.json")
    }

    func read() -> LiveActivityHostSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
            let snapshot = try? JSONDecoder().decode(LiveActivityHostSnapshot.self, from: data),
            snapshot.v == LiveActivityHostSnapshot.currentVersion
        else { return nil }
        return snapshot
    }

    func write(_ snapshot: LiveActivityHostSnapshot) {
        guard var url = fileURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        } catch {
            return
        }
    }
}
