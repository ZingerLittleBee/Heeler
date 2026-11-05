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

    /// Why herdr-core refuses this name, nil when it takes it.
    static func refusal(_ value: String) -> String? {
        guard !isValid(value) else { return nil }
        return "herdr-core refuses the session name \"\(normalized(value))\". A name cannot be \".\" or "
            + "\"..\", or contain control characters or any of / \\ : * ? \" < > |."
    }

    /// Why a native Windows Host cannot carry this name, which the core may accept.
    /// `connect --session` goes through `cmd`, then maybe PowerShell before it, and
    /// no quoting survives both, so only hc's own advice for a name does: letters,
    /// digits, `-`, `_` and `.`. Nil for a name it can carry.
    static func windowsRefusal(_ value: String) -> String? {
        let name = normalized(value)
        let plain = name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII
                && (CharacterSet.alphanumerics.contains(scalar) || "-_.".unicodeScalars.contains(scalar))
        }
        guard !plain || name.hasPrefix("-") || !isValid(name) else { return nil }
        return "Heeler cannot use the session name \"\(name)\" on native Windows. A name there uses "
            + "letters, digits, \"-\", \"_\" and \".\", and does not start with \"-\"."
    }
}
