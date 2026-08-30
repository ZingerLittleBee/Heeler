import Foundation

/// The compact Agent identity shared by alert notifications and Live
/// Activities. Workspace labels distinguish parallel Agents; the friendly
/// kind remains useful context without exposing terminal titles or custom
/// Agent names.
enum AgentNotificationIdentity {
    static func title(workspace: String?, kind: String) -> String {
        let kind = kindLabel(kind)
        guard let workspace = nonEmpty(workspace) else { return kind }
        return "\(workspace) · \(kind)"
    }

    static func kindLabel(_ rawValue: String) -> String {
        let rawValue = nonEmpty(rawValue) ?? "unknown"
        return switch rawValue.lowercased() {
        case "pi": "Pi"
        case "claude": "Claude"
        case "codex": "Codex"
        case "gemini": "Gemini CLI"
        case "cursor": "Cursor Agent"
        case "devin": "Devin CLI"
        case "agy": "Antigravity"
        case "cline": "Cline"
        case "omp": "OMP"
        case "mastracode": "Mastra Code"
        case "opencode": "OpenCode"
        case "copilot": "GitHub Copilot CLI"
        case "kimi": "Kimi CLI"
        case "kiro": "Kiro CLI"
        case "droid": "Droid"
        case "amp": "Amp"
        case "grok": "Grok Build"
        case "hermes": "Hermes Agent"
        case "kilo": "Kilo Code"
        case "qodercli": "Qoder CLI"
        case "maki": "Maki"
        case "qwen": "Qwen Code"
        case "unknown": "Unknown"
        default: rawValue
        }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
