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
    /// The callable name: `code-review`, never `/code-review`.
    let name: String
    /// The frontmatter description; nil when the file carries none.
    let description: String?
    /// How this agent invokes the name: `/` for slash commands, `$` for
    /// Codex skill mentions, `/skill:` for Pi skills. Rides the skill (not
    /// the kind) because one kind can expose several mechanisms.
    let commandPrefix: String

    init(
        scope: Scope, name: String, description: String?,
        commandPrefix: String = "/"
    ) {
        self.scope = scope
        self.name = name
        self.description = description
        self.commandPrefix = commandPrefix
    }

    /// The invocation as the agent's composer expects it: `/code-review`,
    /// `$skill-name`, `/skill:pdf-tools`.
    var command: String { commandPrefix + name }

    /// Commands are unique per scope after catalog dedupe, so the pair is a
    /// stable identity across refreshes.
    var id: String { "\(scope.rawValue)|\(command)" }

    /// What tapping the skill types into the terminal: the command and a
    /// trailing space, never a submit byte (the Snippets rule).
    var insertionText: String { command + " " }
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
    /// The invocation prefix this source's entries are called with.
    let commandPrefix: String

    init(
        root: Root, relativePath: String, layout: Layout,
        commandPrefix: String = "/"
    ) {
        self.root = root
        self.relativePath = relativePath
        self.layout = layout
        self.commandPrefix = commandPrefix
    }

    var scope: AgentSkill.Scope {
        root == .project ? .project : .global
    }
}

/// The per-kind source table. Adding a kind is adding data here — the probe,
/// parser, and UI are all layout-driven. Paths verified against each agent's
/// official docs/source (2026-08); kinds without an entry get no Skills pane.
///
/// Discovery is one directory level deep (the standard `<name>/SKILL.md`
/// layout). Codex and Pi technically allow nested skill trees, and Pi can
/// add extra roots via its settings files — both are rare enough to stay out
/// of the probe until someone misses them.
enum SkillSourceCatalog {
    /// Project sources come first: the catalog dedupes same-commanded skills
    /// in source order, and a project skill shadows a global one (the same
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
        case .codex:
            // Agent Skills only: `~/.codex/prompts` custom prompts were
            // removed outright in Codex 0.117.0. Skills are invoked with the
            // `$` mention prefix, not a slash.
            [
                SkillSource(
                    root: .project, relativePath: ".codex/skills",
                    layout: .skillDirectories, commandPrefix: "$"),
                SkillSource(
                    root: .project, relativePath: ".agents/skills",
                    layout: .skillDirectories, commandPrefix: "$"),
                SkillSource(
                    root: .home, relativePath: ".agents/skills",
                    layout: .skillDirectories, commandPrefix: "$"),
                // Deprecated in Codex but still loaded; same here.
                SkillSource(
                    root: .home, relativePath: ".codex/skills",
                    layout: .skillDirectories, commandPrefix: "$"),
            ]
        case .opencode:
            // Commands only: stable OpenCode's skills are model-invoked (a
            // `skill` tool), not slash-callable, so listing them here would
            // insert text the composer doesn't understand. Revisit when v2's
            // `/id` skills ship. Singular directory names are the documented
            // backwards-compatible variant.
            [
                SkillSource(
                    root: .project, relativePath: ".opencode/commands",
                    layout: .markdownFiles),
                SkillSource(
                    root: .project, relativePath: ".opencode/command",
                    layout: .markdownFiles),
                SkillSource(
                    root: .home, relativePath: ".config/opencode/commands",
                    layout: .markdownFiles),
                SkillSource(
                    root: .home, relativePath: ".config/opencode/command",
                    layout: .markdownFiles),
            ]
        case .pi:
            // Two mechanisms: Agent Skills (invoked `/skill:<name>`; bare
            // `.md` files at a `.pi`-flavored root also count) and prompt
            // templates (plain `/name`).
            [
                SkillSource(
                    root: .project, relativePath: ".pi/skills",
                    layout: .skillDirectories, commandPrefix: "/skill:"),
                SkillSource(
                    root: .project, relativePath: ".pi/skills",
                    layout: .markdownFiles, commandPrefix: "/skill:"),
                SkillSource(
                    root: .project, relativePath: ".agents/skills",
                    layout: .skillDirectories, commandPrefix: "/skill:"),
                SkillSource(
                    root: .project, relativePath: ".pi/prompts",
                    layout: .markdownFiles),
                SkillSource(
                    root: .home, relativePath: ".pi/agent/skills",
                    layout: .skillDirectories, commandPrefix: "/skill:"),
                SkillSource(
                    root: .home, relativePath: ".pi/agent/skills",
                    layout: .markdownFiles, commandPrefix: "/skill:"),
                SkillSource(
                    root: .home, relativePath: ".agents/skills",
                    layout: .skillDirectories, commandPrefix: "/skill:"),
                SkillSource(
                    root: .home, relativePath: ".pi/agent/prompts",
                    layout: .markdownFiles),
            ]
        default:
            []
        }
    }

    static func supports(_ kind: SupportedAgentKind) -> Bool {
        !sources(for: kind).isEmpty
    }
}
