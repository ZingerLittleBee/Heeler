import Foundation
import Observation

/// Pins the user has chosen on Console rows, keyed by `(hostID, paneID)` —
/// the same identity as `ConsoleAgent.ID`. Array order is recency: most
/// recently pinned first. Entries are never pruned; a pane that has closed
/// leaves a dangling pin so the same pane id coming back after a herdr
/// restart is still pinned.
@MainActor
@Observable
final class PinnedAgentsStore {
    private static let defaultsKey = "pinned-agents"
    private static let blobVersion = 1

    private struct PersistedBlob: Codable {
        let version: Int
        let entries: [Entry]
    }

    private struct Entry: Codable, Equatable {
        let hostID: UUID
        let paneID: String
    }

    private var entries: [Entry]
    // UserDefaults is documented thread-safe; Sendable modulo that promise.
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.defaultsKey) else {
            entries = []
            return
        }
        do {
            let blob = try JSONDecoder().decode(PersistedBlob.self, from: data)
            guard blob.version == Self.blobVersion else {
                entries = []
                return
            }
            entries = blob.entries
        } catch {
            entries = []
        }
    }

    func isPinned(hostID: Host.ID, paneID: String) -> Bool {
        pinRank(hostID: hostID, paneID: paneID) != nil
    }

    /// Pins when unpinned, unpins when pinned. Pinning again moves the
    /// entry to most-recent.
    func togglePin(hostID: Host.ID, paneID: String) {
        if isPinned(hostID: hostID, paneID: paneID) {
            entries.removeAll { $0.hostID == hostID && $0.paneID == paneID }
        } else {
            pin(hostID: hostID, paneID: paneID)
        }
        persist()
    }

    /// Pane ids pinned for this Host, most-recently-pinned first.
    func pinnedPaneIDs(for hostID: Host.ID) -> [String] {
        entries.compactMap { $0.hostID == hostID ? $0.paneID : nil }
    }

    /// 0 = most recently pinned. nil when not pinned.
    func pinRank(hostID: Host.ID, paneID: String) -> Int? {
        entries.firstIndex { $0.hostID == hostID && $0.paneID == paneID }
    }

    /// Inserts at the front after dropping any existing copy, so a re-pin
    /// becomes most-recent without duplicating the entry.
    private func pin(hostID: Host.ID, paneID: String) {
        entries.removeAll { $0.hostID == hostID && $0.paneID == paneID }
        entries.insert(Entry(hostID: hostID, paneID: paneID), at: 0)
    }

    private func persist() {
        let blob = PersistedBlob(version: Self.blobVersion, entries: entries)
        guard let data = try? JSONEncoder().encode(blob) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
