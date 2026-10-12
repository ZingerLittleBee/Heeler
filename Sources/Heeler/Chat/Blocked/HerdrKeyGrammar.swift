import Foundation

/// The key names `agent.send_keys` accepts, mirrored from herdr 0.9.3's
/// `parse_key_combo` (`src/config/keybinds.rs`) and its API aliases
/// (`src/app/api_helpers.rs`). herdr rejects the whole request when one name
/// fails to parse, and it has no `home`, `end`, page or `delete` keys.
enum HerdrKeyGrammar {
    static func accepts(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized =
            switch trimmed {
            case "C-c", "c-c": "ctrl+c"
            case "+": "plus"
            default: trimmed
            }
        var key: String?
        for part in normalized.split(separator: "+", omittingEmptySubsequences: false) {
            let token = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return false }
            if modifiers.contains(token.lowercased()) { continue }
            guard key == nil else { return false }
            key = token
        }
        guard let key else { return false }
        let lowered = key.lowercased()
        if namedKeys.contains(lowered) || key.unicodeScalars.count == 1 { return true }
        // Function keys: `f` and a number that fits in a byte.
        return lowered.hasPrefix("f") && UInt8(lowered.dropFirst()) != nil
    }

    private static let modifiers: Set<String> = [
        "ctrl", "control", "shift", "alt", "option", "meta", "cmd", "command", "super", "hyper",
    ]

    private static let namedKeys: Set<String> = [
        "space", "enter", "return", "esc", "escape", "tab", "backspace", "bs", "left", "right", "up", "down",
        "minus", "comma", "period", "slash", "backslash", "quote", "double_quote", "double-quote", "semicolon",
        "colon", "percent", "ampersand", "backtick", "plus",
    ]
}
