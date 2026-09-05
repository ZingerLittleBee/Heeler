import Foundation
import Observation

enum AgentRowLayoutStoreError: Error, Equatable {
    case catalogUnreadable
}

/// Local whole-layout overrides. Plugin snapshots belong to the connection
/// that fetched them and are deliberately not persisted in this catalog.
@MainActor
@Observable
final class AgentRowLayoutStore {
    private static let defaultsKey = "agent-row-layouts"
    private static let catalogVersion = 1

    private struct PersistedCatalog: Codable {
        let version: Int
        let hostLayouts: [Host.ID: AgentRowLayout]
        let globalLayout: AgentRowLayout?
    }

    private(set) var hostLayouts: [Host.ID: AgentRowLayout] = [:]
    private(set) var globalLayout: AgentRowLayout?
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
            globalLayout = catalog.globalLayout
        } catch {
            catalogLoadError = .catalogUnreadable
        }
    }

    /// nil removes only this Host's override and restores inheritance.
    func setLayout(_ layout: AgentRowLayout?, for hostID: Host.ID) throws {
        var updated = hostLayouts
        updated[hostID] = layout
        try persist(hostLayouts: updated, globalLayout: globalLayout)
        hostLayouts = updated
    }

    /// nil restores plugin/default inheritance for Hosts without overrides.
    func setGlobalLayout(_ layout: AgentRowLayout?) throws {
        try persist(hostLayouts: hostLayouts, globalLayout: layout)
        globalLayout = layout
    }

    func resolvedLayout(for hostID: Host.ID, pluginSnapshot: AgentRowLayoutSnapshot?) -> AgentRowLayout {
        AgentRowLayoutResolver.resolve(
            hostLayout: hostLayouts[hostID], globalLayout: globalLayout, pluginSnapshot: pluginSnapshot)
    }

    private func persist(hostLayouts: [Host.ID: AgentRowLayout], globalLayout: AgentRowLayout?) throws {
        guard catalogLoadError == nil else { throw AgentRowLayoutStoreError.catalogUnreadable }
        try globalLayout?.validate()
        for layout in hostLayouts.values { try layout.validate() }
        let encoded = try JSONEncoder().encode(PersistedCatalog(
            version: Self.catalogVersion, hostLayouts: hostLayouts, globalLayout: globalLayout))
        defaults.set(encoded, forKey: Self.defaultsKey)
    }
}
