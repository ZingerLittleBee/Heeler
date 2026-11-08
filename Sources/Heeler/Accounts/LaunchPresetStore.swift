import Foundation
import Observation

/// The device's Launch Presets (#622), in the order the user keeps them.
/// Saved as JSON in the user defaults; a preset this app cannot read is
/// dropped rather than failing the rest.
@MainActor
@Observable
final class LaunchPresetStore {
    struct SaveError: Error, Equatable {
        let message: String
    }

    static let defaultsKey = "launch-presets.v1"

    private(set) var presets: [LaunchPreset] = []
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        presets = Self.load(from: defaults)
    }

    /// Why `preset` cannot be saved as it stands; nil when it can.
    func problem(with preset: LaunchPreset) -> String? {
        let name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return String(localized: "Enter a name for this preset.") }
        if presets.contains(where: {
            $0.id != preset.id && $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(name) == .orderedSame
        }) {
            return String(localized: "Another preset is named \(name).")
        }
        if case .failure(let error) = StartAgentStore.parseArguments(
            StartAgentStore.normalizeSmartPunctuation(preset.arguments))
        {
            return error.message
        }
        var seen: Set<String> = []
        for variable in preset.environment where !variable.isBlank {
            let variableName = variable.name.trimmingCharacters(in: .whitespaces)
            guard !variableName.isEmpty else { return String(localized: "Enter a name for each variable.") }
            guard UsageAccountFile.isVariable(variableName) else { return String(localized: "\(variableName) is not a variable name.") }
            guard seen.insert(variableName).inserted else { return String(localized: "\(variableName) is set twice.") }
        }
        return nil
    }

    /// Adds `preset` at the end, or replaces the one with its id.
    func save(_ preset: LaunchPreset) throws(SaveError) {
        if let problem = problem(with: preset) { throw SaveError(message: problem) }
        var preset = preset
        preset.name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        preset.environment = preset.environment.filter { !$0.isBlank }.map {
            .init(name: $0.name.trimmingCharacters(in: .whitespaces), value: $0.value)
        }
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        persist()
    }

    func delete(_ id: LaunchPreset.ID) {
        presets.removeAll { $0.id == id }
        persist()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        presets.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    /// The presets New Agent offers for a Host that has `kinds`.
    func presets(for kinds: [SupportedAgentKind]) -> [LaunchPreset] {
        presets.filter { kinds.contains($0.kind) }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func load(from defaults: UserDefaults) -> [LaunchPreset] {
        guard let data = defaults.data(forKey: defaultsKey),
            let entries = try? JSONDecoder().decode([Lenient].self, from: data)
        else { return [] }
        return entries.compactMap(\.preset)
    }

    /// One saved entry, nil when it cannot be read (a harness a newer app
    /// knows, say).
    private struct Lenient: Decodable {
        let preset: LaunchPreset?

        init(from decoder: any Decoder) throws {
            preset = try? LaunchPreset(from: decoder)
        }
    }
}
