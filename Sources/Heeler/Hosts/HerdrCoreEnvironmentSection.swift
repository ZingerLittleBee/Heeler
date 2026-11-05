import SwiftUI

/// What a core Host says about the variables its core inherited (ADR 0034).
/// It only tells: Heeler never restarts a core, so this offers no action.
struct HerdrCoreEnvironmentNotice: Equatable, Sendable {
    struct Variable: Equatable, Identifiable, Sendable {
        let name: String
        let breaks: String

        var id: String { name }
    }

    static let fix = "Restarting the core from your own terminal fixes this. Heeler does not restart it."

    /// In the order ADR 0034 lists them, a `HERDR_*` run sorted by name.
    let variables: [Variable]

    /// Nil when nothing leaked.
    init?(names: Set<String>) {
        guard !names.isEmpty else { return nil }
        variables = names.sorted { lhs, rhs in
            let ranks = (Self.rank(lhs), Self.rank(rhs))
            return ranks.0 == ranks.1 ? lhs < rhs : ranks.0 < ranks.1
        }
        .map { Variable(name: $0, breaks: Self.breaks($0)) }
    }

    /// `HERDR_*` shares `CLAUDECODE`'s rank and sorts after it by name.
    private static func rank(_ name: String) -> Int {
        HerdrCoreEnvironmentCheck.names.firstIndex(of: name)
            ?? HerdrCoreEnvironmentCheck.names.firstIndex(of: "CLAUDECODE") ?? 0
    }

    /// Worded from herdr compatibility's observations where one exists. The
    /// variables with none only say what a program would take the Terminal for.
    private static func breaks(_ name: String) -> String {
        switch name {
        case "CLAUDE_CODE_CHILD_SESSION":
            // Claude Code 2.1.316 honored 1 and ignored a made-up value (#579).
            "Set to 1, Claude Code keeps no session record and saves no conversation, so Chat has nothing to show."
        case "CLAUDE_CODE_SKIP_PROMPT_HISTORY":
            "Claude Code saves no conversation, so Chat has nothing to show."
        case "CLAUDECODE":
            "Programs here read as started from inside Claude Code, which can change what they report and record."
        case "TMUX":
            "Grok Build turns its status off inside tmux, so its Agents read Unknown."
        case "STY":
            "Grok Build turns its status off inside GNU Screen, so its Agents read Unknown."
        case "ZELLIJ":
            "Grok Build turns its status off inside Zellij, so its Agents read Unknown."
        case "CURSOR_TRACE_ID":
            "Claude Code reads Terminals here as Cursor's, which can change what it reports."
        case "VSCODE_GIT_ASKPASS_MAIN":
            "Claude Code reads Terminals here as a code editor's, which can change what it reports."
        case "CODEX_THREAD_ID":
            "Programs here read as started from a Codex thread, which can change what they report and record."
        case "OMPCODE":
            "Programs here read as started from inside Oh My Pi, which can change what they report and record."
        case "PI_PROGRAM_STATUS":
            "Set to 0, it turns Pi's status off, so its Agents read Unknown."
        case "HERDR_PANE_ID":
            "Herdr's agent hooks report to the pane this names, not to the Terminal they run in."
        default:
            // Any other `HERDR_*` name, which may name no pane at all.
            "Terminals here inherit it, so a program that reads Herdr's variables may act as if it runs inside Herdr."
        }
    }
}

/// Below a core Host's checks, while its core carries leaked variables.
struct HerdrCoreEnvironmentSection: View {
    let notice: HerdrCoreEnvironmentNotice

    var body: some View {
        Section {
            ForEach(notice.variables) { @Sendable variable in
                MainActorContent {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: variable.name)
                            .font(.callout.monospaced())
                        Text(variable.breaks)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("hosts.detail.coreEnvironment.\(variable.name)")
                }
            }
        } header: {
            Text("Core Environment")
        } footer: {
            Text(HerdrCoreEnvironmentNotice.fix)
                .accessibilityIdentifier("hosts.detail.coreEnvironment.fix")
        }
    }
}
