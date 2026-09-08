import Foundation

/// A user-chosen name for one pane session, kept on this device (#290).
///
/// herdr's server-side `agent.rename` is restricted to `^[a-z][a-z0-9_-]{0,31}$`
/// and only covers Agents; the Console otherwise names a row by its workspace
/// label, which is identical for every Agent in one workspace. A local name
/// tells sessions apart without a Host round-trip, accepts free text, and
/// works for every pane. It never leaves the device, so it never conflicts
/// with herdr's own rename.
@MainActor
final class PaneNameStore {
    private static let defaultsKey = "pane-names"
    private static let blobVersion = 1

    private struct PersistedBlob: Codable {
        let version: Int
        let entries: [Entry]
    }

    private struct Entry: Codable, Equatable {
        let hostID: UUID
        let paneID: String
        let name: String
    }

    private var entries: [Entry]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.defaultsKey) else {
            entries = []
            return
        }
        do {
            let blob = try JSONDecoder().decode(PersistedBlob.self, from: data)
            guard blob.version == Self.blobVersion else {
                // Names are cheap to lose: unknown versions start empty and
                // the next write clobbers them, like PinnedAgentsStore.
                entries = []
                return
            }
            entries = blob.entries
        } catch {
            entries = []
        }
    }

    /// The stored name for one pane session, nil when unset.
    func name(hostID: Host.ID, paneID: String) -> String? {
        entries.first { $0.hostID == hostID && $0.paneID == paneID }?.name
    }

    /// Sets the name for one pane session. Empty or whitespace-only input
    /// clears the entry back to unset.
    func set(_ name: String, hostID: Host.ID, paneID: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        entries.removeAll { $0.hostID == hostID && $0.paneID == paneID }
        guard !trimmed.isEmpty else {
            persist()
            return
        }
        entries.append(Entry(hostID: hostID, paneID: paneID, name: trimmed))
        persist()
    }

    private func persist() {
        let blob = PersistedBlob(version: Self.blobVersion, entries: entries)
        guard let data = try? JSONEncoder().encode(blob) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}