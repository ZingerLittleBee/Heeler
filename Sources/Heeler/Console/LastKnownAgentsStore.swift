import Foundation

/// Last-known Agent inventory (#237): per-Host metadata-only rows persisted
/// at snapshot time, so a launch that has not synced yet shows stale rows
/// instead of claiming the Console is empty. Terminal output and live
/// presence are never cached — a row read from here is always stale, and
/// the Console renders it disabled until its Host's first current-generation
/// snapshot replaces it.
@MainActor
@Observable
final class LastKnownAgentsStore {
    /// One row of the last-known inventory: identity plus the display facts
    /// a disabled Console row needs. `statusLabel` is the last-seen status,
    /// never a live claim.
    struct CachedAgent: Codable, Equatable, Identifiable, Sendable {
        var id: ConsoleAgent.ID { ConsoleAgent.ID(hostID: hostID, paneID: paneID) }
        let hostID: Host.ID
        let hostName: String
        let paneID: String
        let displayName: String
        let statusLabel: String
        let workspaceLabel: String?
        let tabLabel: String?
        let paneLabel: String?
        let snapshotOrder: Int?

        init(from agent: ConsoleAgent) {
            hostID = agent.hostID
            hostName = agent.hostName
            paneID = agent.agent.paneID
            displayName = agent.agent.displayName
            statusLabel = agent.agent.status.rawValue
            workspaceLabel = agent.workspaceLabel
            tabLabel = agent.tabLabel
            paneLabel = agent.paneLabel
            snapshotOrder = agent.snapshotOrder
        }
    }

    // Internal (not private) so tests can plant corrupt blobs: persisted
    // records are untrusted input and the corrupt path must stay covered.
    static let defaultsKey = "last-known-agents"
    private static let blobVersion = 1
    /// Bounds UserDefaults growth: rows are small metadata, but a snapshot
    /// is server data and must not grow the blob without limit.
    private static let maxRowsPerHost = 500

    private struct PersistedBlob: Codable {
        let version: Int
        let hosts: [HostEntry]
    }

    private struct HostEntry: Codable {
        let hostID: Host.ID
        let hostName: String
        let agents: [CachedAgent]
    }

    private let defaults: UserDefaults
    private(set) var agentsByHost: [Host.ID: [CachedAgent]] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return }
        do {
            let blob = try JSONDecoder().decode(PersistedBlob.self, from: data)
            guard blob.version == Self.blobVersion else {
                // Unknown versions start empty and the next write clobbers
                // them: a cache is cheap to lose, unlike live state.
                return
            }
            agentsByHost = Dictionary(
                uniqueKeysWithValues: blob.hosts.map { ($0.hostID, $0.agents) })
        } catch {
            // Corrupt records never block the Console: start empty and let
            // the next authoritative snapshot rewrite the blob.
            return
        }
    }

    /// Atomically replaces one Host's cache: the first current-generation
    /// snapshot is the whole inventory, so absent Agents disappear and an
    /// empty snapshot clears the Host instead of leaving stale rows beside
    /// "No Agents". An empty replace removes the Host's entry.
    func replace(hostID: Host.ID, hostName: String, rows: [CachedAgent]) {
        if rows.isEmpty {
            if agentsByHost.removeValue(forKey: hostID) != nil {
                persist()
            }
            return
        }
        let ordered = rows.sorted {
            let lhsOrder = $0.snapshotOrder ?? Int.max
            let rhsOrder = $1.snapshotOrder ?? Int.max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return $0.paneID < $1.paneID
        }
        let capped = Array(ordered.prefix(Self.maxRowsPerHost))
        if agentsByHost[hostID] != capped {
            agentsByHost[hostID] = capped
            persist()
        }
    }

    /// Removing a Host removes its cache (#237): entries for Hosts outside
    /// the catalog are dropped, never shown.
    func removeHosts(notIn hostIDs: Set<Host.ID>) {
        let pruned = agentsByHost.filter { hostIDs.contains($0.key) }
        if pruned.count != agentsByHost.count {
            agentsByHost = pruned
            persist()
        }
    }

    private func persist() {
        let hosts = agentsByHost.map { HostEntry(hostID: $0.key, hostName: $0.value.first?.hostName ?? "", agents: $0.value) }
        let blob = PersistedBlob(version: Self.blobVersion, hosts: hosts)
        guard let data = try? JSONEncoder().encode(blob) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
