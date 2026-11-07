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

    /// One file or folder a harness keeps in its config directory.
    struct AccountMarker: Sendable {
        let name: String
        let kind: RemoteFileKind

        /// How a refusal lists the marker: a folder as "a … folder", a file
        /// by its name alone.
        var label: String { kind == .directory ? String(localized: "a \(name) folder") : name }
    }

    /// What tells a harness's config directory apart from any folder: one
    /// of these is enough. Empty where Heeler knows none; any directory
    /// then does.
    var accountMarkers: [AccountMarker] {
        switch self {
        case .claude: [.init(name: ".claude.json", kind: .regular), .init(name: "projects", kind: .directory)]
        case .codex:
            [
                .init(name: "auth.json", kind: .regular), .init(name: "config.toml", kind: .regular),
                .init(name: "sessions", kind: .directory),
            ]
        case .grok, .pi, .omp: [.init(name: "sessions", kind: .directory)]
        default: []
        }
    }
}
