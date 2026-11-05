import Foundation

extension SupportedAgentKind {
    /// The environment variable a harness reads its config directory from,
    /// so an Account's directory can be handed to an Agent it launches.
    /// Nil where Heeler does not know one; the user names it in Accounts.
    var configDirectoryVariable: String? {
        switch self {
        case .claude: "CLAUDE_CONFIG_DIR"
        case .codex: "CODEX_HOME"
        case .grok: "GROK_HOME"
        case .pi: "PI_CODING_AGENT_DIR"
        // The folder that holds `.gemini`, not `.gemini` itself.
        case .gemini: "GEMINI_CLI_HOME"
        default: nil
        }
    }
}
