import Foundation

/// Client-side mirror of the server's agent-name rule, shared by the
/// new-agent form (#12) and the rename sheet (#98) so the copy and the rule
/// cannot drift. The server enforces `^[a-z][a-z0-9_-]{0,31}$` and rejects
/// violations with `invalid_agent_name` (verified live against herdr 0.7.5);
/// validating here explains the rule before a round trip.
enum AgentName {
    /// Nil when `name` is an acceptable agent name; otherwise a user-facing
    /// message stating the rule. Empty is invalid here like on the server;
    /// callers intercept emptiness first when it carries meaning ("generate
    /// a default" on the start form, "clear back to the detected kind" on
    /// the rename sheet).
    static func validationError(_ name: String) -> String? {
        let message =
            "Agent names are 1–32 characters: lowercase letters, digits, "
            + "- or _, starting with a lowercase letter."
        guard !name.isEmpty, name.count <= 32 else { return message }
        for (offset, character) in name.enumerated() {
            guard character.unicodeScalars.count == 1,
                let scalar = character.unicodeScalars.first
            else { return message }
            switch scalar.value {
            case 0x61...0x7A:  // a-z
                continue
            case 0x30...0x39, 0x2D, 0x5F:  // 0-9, '-', '_'
                if offset == 0 { return message }
            default:
                return message
            }
        }
        return nil
    }
}
