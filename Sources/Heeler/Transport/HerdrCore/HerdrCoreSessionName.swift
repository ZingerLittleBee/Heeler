import Foundation

/// The folder-name contract from herdr-core 0.1.13 paths.rs. Socket path
/// length depends on the remote platform and is checked by the core itself.
enum HerdrCoreSessionName {
    static func normalized(_ value: String) -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "default" : name
    }

    static func isValid(_ value: String) -> Bool {
        let name = normalized(value)
        return name != "." && name != ".."
            && !name.unicodeScalars.contains {
                $0.properties.generalCategory == .control || #"/\:*?"<>|"#.unicodeScalars.contains($0)
            }
    }
}
