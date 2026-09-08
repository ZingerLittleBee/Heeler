import Foundation
import Observation

enum AgentRowLayoutStoreError: Error, Equatable {
    case catalogUnreadable
}

/// Per-Host whole-layout choices. Plugin snapshots belong to the connection
/// that fetched them and are deliberately not persisted in this catalog.
@MainActor
@Observable
final class AgentRowLayoutStore {
    private static let defaultsKey = "agent-row-layouts"
    private static let catalogVersion = 1

    /// Earlier version-1 catalogs also carried a `globalLayout`. It is
    /// ignored on load and dropped by the next write, so a hidden legacy
    /// choice can never override a Host's herdr fields.
    private struct PersistedCatalog: Codable {
        let version: Int
        let hostLayouts: [Host.ID: AgentRowLayout]
    }

    private(set) var hostLayouts: [Host.ID: AgentRowLayout] = [:]
    private(set) var catalogLoadError: AgentRowLayoutStoreError?
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return }
        do {
            let catalog = try JSONDecoder().decode(PersistedCatalog.self, from: data)
            guard catalog.version == Self.catalogVersion else {
                throw AgentRowLayoutStoreError.catalogUnreadable
            }
            hostLayouts = catalog.hostLayouts
        } catch {
            catalogLoadError = .catalogUnreadable
        }
    }

    /// nil removes this Host's choice so its herdr fields apply again.
    func setLayout(_ layout: AgentRowLayout?, for hostID: Host.ID) throws {
        try setLayouts([hostID: layout])
    }

    /// One validated write for every Host in `changes`; either all of them
    /// are saved or none is.
    func setLayouts(_ changes: [Host.ID: AgentRowLayout?]) throws {
        var updated = hostLayouts
        for (hostID, layout) in changes { updated[hostID] = layout }
        try persist(hostLayouts: updated)
        hostLayouts = updated
    }

    func resolvedLayout(for hostID: Host.ID, pluginSnapshot: AgentRowLayoutSnapshot?) -> AgentRowLayout {
        AgentRowLayoutResolver.resolve(hostLayout: hostLayouts[hostID], pluginSnapshot: pluginSnapshot)
    }

    private func persist(hostLayouts: [Host.ID: AgentRowLayout]) throws {
        guard catalogLoadError == nil else { throw AgentRowLayoutStoreError.catalogUnreadable }
        for layout in hostLayouts.values { try layout.validate() }
        let encoded = try JSONEncoder().encode(PersistedCatalog(
            version: Self.catalogVersion, hostLayouts: hostLayouts))
        defaults.set(encoded, forKey: Self.defaultsKey)
    }
}
