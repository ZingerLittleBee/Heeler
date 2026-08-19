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
    /// Increments on every pin toggle so observers (Live Activity) can
    /// rebuild without waiting for the Console list to change identity.
    private(set) var revision: UInt64 = 0
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
                // Pins are cheap to lose: unknown versions start empty and the next write clobbers them, unlike SnippetStore's no-write policy.
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
        revision += 1
    }

    /// Pane ids pinned for this Host, most-recently-pinned first.
    func pinnedPaneIDs(for hostID: Host.ID) -> [String] {
        entries.compactMap { $0.hostID == hostID ? $0.paneID : nil }
    }

    /// Position in the global pin recency order (lower = more recent).
    /// Comparable across Hosts; not an index into `pinnedPaneIDs(for:)`.
    func pinRank(hostID: Host.ID, paneID: String) -> Int? {
        entries.firstIndex { $0.hostID == hostID && $0.paneID == paneID }
    }

    private func pin(hostID: Host.ID, paneID: String) {
        entries.insert(Entry(hostID: hostID, paneID: paneID), at: 0)
    }

    private func persist() {
        let blob = PersistedBlob(version: Self.blobVersion, entries: entries)
        guard let data = try? JSONEncoder().encode(blob) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
