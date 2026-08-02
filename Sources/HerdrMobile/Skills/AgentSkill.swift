import Foundation

/// One skill or custom slash command discovered for an agent kind on a Host.
///
/// "Skill" is used loosely: for Claude Code these are Agent Skills
/// (`SKILL.md`), for other kinds they are whatever that agent calls its
/// user-defined slash commands. The Skills keyboard pane treats them all the
/// same way — a name to insert and a description to read.
struct AgentSkill: Identifiable, Sendable, Equatable, Hashable {
    enum Scope: String, Sendable {
        /// Found under the agent's project root; typically checked into the
        /// repository the agent is working in.
        case project
        /// Found under the remote home directory; available in every project.
        case global
    }

    let scope: Scope
    /// The slash-callable name: `code-review`, never `/code-review`.
    let name: String
    /// The frontmatter description; nil when the file carries none.
    let description: String?

    /// Names are unique per scope after catalog dedupe, so the pair is a
    /// stable identity across refreshes.
    var id: String { "\(scope.rawValue)/\(name)" }

    /// What tapping the skill types into the terminal: the slash command and
    /// a trailing space, never a submit byte (the Snippets rule).
    var insertionText: String { "/\(name) " }
}

/// Where one agent kind keeps its skills on a Host. `relativePath` is a
/// compile-time constant interpolated into the probe script — it must never
/// carry user input.
struct SkillSource: Sendable, Equatable {
    enum Root: Sendable, Equatable {
        case home
        case project
    }

    enum Layout: Sendable, Equatable {
        /// `<dir>/<name>/SKILL.md`; the name comes from frontmatter, falling
        /// back to the directory name.
        case skillDirectories
        /// `<dir>/<name>.md`; the name is the filename stem.
        case markdownFiles
    }

    let root: Root
    /// Relative to the root, without a leading slash.
    let relativePath: String
    let layout: Layout

    var scope: AgentSkill.Scope {
        root == .project ? .project : .global
    }
}

/// The per-kind source table. Adding a kind is adding data here — the probe,
/// parser, and UI are all layout-driven. Paths verified against each agent's
/// official docs; kinds without an entry get no Skills pane.
enum SkillSourceCatalog {
    /// Project sources come first: the catalog dedupes same-named skills in
    /// source order, and a project skill shadows a global one (the same
    /// precedence the agents themselves apply).
    static func sources(for kind: SupportedAgentKind) -> [SkillSource] {
        switch kind {
        case .claude:
            [
                SkillSource(
                    root: .project, relativePath: ".claude/skills",
                    layout: .skillDirectories),
                SkillSource(
                    root: .home, relativePath: ".claude/skills",
                    layout: .skillDirectories),
            ]
        default:
            []
        }
    }

    static func supports(_ kind: SupportedAgentKind) -> Bool {
        !sources(for: kind).isEmpty
    }
}
