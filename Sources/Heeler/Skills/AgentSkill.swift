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
    /// Where the probe found the file on the Host, so the full document can
    /// be fetched on demand.
    let path: String

    init(
        scope: Scope, name: String, description: String?,
        commandPrefix: String = "/", path: String = ""
    ) {
        self.scope = scope
        self.name = name
        self.description = description
        self.commandPrefix = commandPrefix
        self.path = path
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
        case .antigravity:
            // Skills double as slash commands (`/name`), and a bare
            // markdown file in the workspace root also counts
            // (`.agents/skills/lint.md` → `/lint`). Global discovery is
            // messy across the AGY flavours: the CLI's `/skills` reports
            // `~/.gemini/antigravity-cli/skills`, while
            // `~/.gemini/config/skills` is the one location every flavour
            // recognises — probe both.
            [
                SkillSource(
                    root: .project, relativePath: ".agents/skills",
                    layout: .skillDirectories),
                SkillSource(
                    root: .project, relativePath: ".agents/skills",
                    layout: .markdownFiles),
                SkillSource(
                    root: .home, relativePath: ".gemini/antigravity-cli/skills",
                    layout: .skillDirectories),
                SkillSource(
                    root: .home, relativePath: ".gemini/config/skills",
                    layout: .skillDirectories),
            ]
        case .cline:
            // Skills only, shipped in Cline 3.48 and invoked `/skill-name`.
            // Workflows stay out: they are invoked with their `.md` suffix
            // (`/pr-review.md`), which the markdown layout's stripped stem
            // would misquote. Cline resolves global over project on a name
            // clash — the opposite of the shadowing here; rare enough to
            // ignore.
            [
                SkillSource(
                    root: .project, relativePath: ".cline/skills",
                    layout: .skillDirectories),
                SkillSource(
                    root: .project, relativePath: ".clinerules/skills",
                    layout: .skillDirectories),
                SkillSource(
                    root: .home, relativePath: ".cline/skills",
                    layout: .skillDirectories),
            ]
        case .copilot:
            // Skills double as slash commands (`/skill-name` in the
            // prompt); there is no separate command-file mechanism.
            // `.github/skills` is Copilot's own project root.
            [
                SkillSource(
                    root: .project, relativePath: ".github/skills",
                    layout: .skillDirectories),
                SkillSource(
                    root: .project, relativePath: ".agents/skills",
                    layout: .skillDirectories),
                SkillSource(
                    root: .home, relativePath: ".copilot/skills",
                    layout: .skillDirectories),
                SkillSource(
                    root: .home, relativePath: ".agents/skills",
                    layout: .skillDirectories),
            ]
        case .cursor:
            // Agent Skills shipped in Cursor 2.4 for both the editor and the
            // CLI, invoked from the `/` menu. Cursor also loads the Claude
            // and Codex directories for compatibility and discovers nested
            // monorepo skill folders; both stay out until someone misses
            // them, like the nested trees noted above. `.cursor/commands`
            // stays out too — CLI support for custom commands is reported
            // inconsistent on the Cursor forum.
            [
                SkillSource(
                    root: .project, relativePath: ".cursor/skills",
                    layout: .skillDirectories),
                SkillSource(
                    root: .project, relativePath: ".agents/skills",
                    layout: .skillDirectories),
                SkillSource(
                    root: .home, relativePath: ".cursor/skills",
                    layout: .skillDirectories),
                SkillSource(
                    root: .home, relativePath: ".agents/skills",
                    layout: .skillDirectories),
            ]
        case .devin:
            // `/skill-name`; the directory name is the identifier.
            // `.windsurf/skills` shares the format (same product family),
            // and the `.agents` standard is supported. The per-channel
            // `~/.codeium/<channel>/skills` roots stay out — the channel
            // is not knowable from here.
            [
                SkillSource(
                    root: .project, relativePath: ".devin/skills",
                    layout: .skillDirectories),
                SkillSource(
                    root: .project, relativePath: ".windsurf/skills",
                    layout: .skillDirectories),
                SkillSource(
                    root: .project, relativePath: ".agents/skills",
                    layout: .skillDirectories),
                SkillSource(
                    root: .home, relativePath: ".config/devin/skills",
                    layout: .skillDirectories),
                SkillSource(
                    root: .home, relativePath: ".agents/skills",
                    layout: .skillDirectories),
            ]
        case .droid:
            // Skills (`/skill-name`) plus legacy markdown commands
            // (`.factory/commands/*.md`, `/name`, still supported). On a
            // name clash Droid gives the command the slash name, so
            // commands probe before skills to match.
            [
                SkillSource(
                    root: .project, relativePath: ".factory/commands",
                    layout: .markdownFiles),
                SkillSource(
                    root: .project, relativePath: ".factory/skills",
                    layout: .skillDirectories),
                SkillSource(
                    root: .project, relativePath: ".agents/skills",
                    layout: .skillDirectories),
                SkillSource(
                    root: .home, relativePath: ".factory/commands",
                    layout: .markdownFiles),
                SkillSource(
                    root: .home, relativePath: ".factory/skills",
                    layout: .skillDirectories),
                SkillSource(
                    root: .home, relativePath: ".agents/skills",
                    layout: .skillDirectories),
            ]
        case .grok:
            // `/skill-name`. Grok itself walks `.grok/skills` up to the
            // repo root; the probe reads the launch directory's only. Rhai
            // workflows are scripts, not markdown, and stay out.
            [
                SkillSource(
                    root: .project, relativePath: ".grok/skills",
                    layout: .skillDirectories),
                SkillSource(
                    root: .home, relativePath: ".grok/skills",
                    layout: .skillDirectories),
                SkillSource(
                    root: .home, relativePath: ".agents/skills",
                    layout: .skillDirectories),
            ]
        case .hermes:
            // `/skill-name`. The global root conventionally nests one
            // category level (`~/.hermes/skills/<category>/<name>/SKILL.md`),
            // which the one-level probe cannot see — same stance as the
            // nested Codex and Pi trees above; project skills and the
            // shared standard root are flat.
            [
                SkillSource(
                    root: .project, relativePath: ".hermes/skills",
                    layout: .skillDirectories),
                SkillSource(
                    root: .project, relativePath: ".agents/skills",
                    layout: .skillDirectories),
                SkillSource(
                    root: .home, relativePath: ".hermes/skills",
                    layout: .skillDirectories),
            ]
        case .kilo:
            // Commands/workflows only (`/name`, markdown): the current CLI
            // roots plus the still-documented legacy workflow directories.
            // Kilo skill directories are not documented for the CLI, so
            // they stay out until they are.
            [
                SkillSource(
                    root: .project, relativePath: ".kilo/commands",
                    layout: .markdownFiles),
                SkillSource(
                    root: .project, relativePath: ".kilocode/workflows",
                    layout: .markdownFiles),
                SkillSource(
                    root: .home, relativePath: ".config/kilo/commands",
                    layout: .markdownFiles),
                SkillSource(
                    root: .home, relativePath: ".kilocode/workflows",
                    layout: .markdownFiles),
            ]
        case .kimi:
            // Agent Skills invoked `/skill:<name>`; flat markdown files are
            // accepted alongside skill directories. Kimi also reads the
            // Claude and Codex brand directories — those compat roots stay
            // out, like Cursor's.
            [
                SkillSource(
                    root: .project, relativePath: ".kimi/skills",
                    layout: .skillDirectories, commandPrefix: "/skill:"),
                SkillSource(
                    root: .project, relativePath: ".kimi/skills",
                    layout: .markdownFiles, commandPrefix: "/skill:"),
                SkillSource(
                    root: .project, relativePath: ".agents/skills",
                    layout: .skillDirectories, commandPrefix: "/skill:"),
                SkillSource(
                    root: .home, relativePath: ".kimi/skills",
                    layout: .skillDirectories, commandPrefix: "/skill:"),
                SkillSource(
                    root: .home, relativePath: ".kimi/skills",
                    layout: .markdownFiles, commandPrefix: "/skill:"),
                SkillSource(
                    root: .home, relativePath: ".config/agents/skills",
                    layout: .skillDirectories, commandPrefix: "/skill:"),
                SkillSource(
                    root: .home, relativePath: ".agents/skills",
                    layout: .skillDirectories, commandPrefix: "/skill:"),
            ]
        case .kiro:
            // The open standard verbatim: workspace and global skill
            // directories, `/skill-name`, nothing else.
            [
                SkillSource(
                    root: .project, relativePath: ".kiro/skills",
                    layout: .skillDirectories),
                SkillSource(
                    root: .home, relativePath: ".kiro/skills",
                    layout: .skillDirectories),
            ]
        case .omp:
            // `/skill:<name>` is always recognised; the plain per-skill
            // slash command rides a config toggle
            // (`skills.enableSkillCommands`), so the prefix form is the
            // safe insertion. omp also inherits `.claude`, `.cursor`, and
            // friends wholesale — compat roots stay out, like Cursor's.
            [
                SkillSource(
                    root: .project, relativePath: ".agents/skills",
                    layout: .skillDirectories, commandPrefix: "/skill:"),
                SkillSource(
                    root: .project, relativePath: ".agent/skills",
                    layout: .skillDirectories, commandPrefix: "/skill:"),
                SkillSource(
                    root: .project, relativePath: ".github/skills",
                    layout: .skillDirectories, commandPrefix: "/skill:"),
                SkillSource(
                    root: .home, relativePath: ".omp/agent/managed-skills",
                    layout: .skillDirectories, commandPrefix: "/skill:"),
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
        case .qodercli:
            // One root per level serves both mechanisms: bare `.md` files
            // are commands, and a subdirectory holding a `SKILL.md`
            // registers as a single command too. Qoder resolves user over
            // project on a name clash — the opposite of the shadowing
            // here, like Cline; namespaced subdirectories
            // (`git/commit.md` → `/git:commit`) are beyond the one-level
            // probe.
            [
                SkillSource(
                    root: .project, relativePath: ".qoder/commands",
                    layout: .markdownFiles),
                SkillSource(
                    root: .project, relativePath: ".qoder/commands",
                    layout: .skillDirectories),
                SkillSource(
                    root: .home, relativePath: ".qoder/commands",
                    layout: .markdownFiles),
                SkillSource(
                    root: .home, relativePath: ".qoder/commands",
                    layout: .skillDirectories),
            ]
        case .qwen:
            // Skills are `/name`-invocable; commands are markdown since the
            // fork diverged from Gemini's TOML (which is deprecated but
            // still read — and unparseable here). Namespaced command
            // subdirectories (`git/commit.md` → `/git:commit`) are beyond
            // the one-level probe.
            [
                SkillSource(
                    root: .project, relativePath: ".qwen/skills",
                    layout: .skillDirectories),
                SkillSource(
                    root: .project, relativePath: ".qwen/commands",
                    layout: .markdownFiles),
                SkillSource(
                    root: .home, relativePath: ".qwen/skills",
                    layout: .skillDirectories),
                SkillSource(
                    root: .home, relativePath: ".qwen/commands",
                    layout: .markdownFiles),
            ]
        // Researched and deliberately absent, not merely unknown:
        // Gemini CLI's skills are model-invoked only (no typed prefix) and
        // its custom commands are TOML; Amp removed custom commands and
        // invokes skills from a palette, again with no typed prefix — both
        // would insert text their composer doesn't understand, the
        // opencode-stable rule. Mastra Code and Maki document no on-disk
        // skill or command discovery at all (Mastra's "skills" are a
        // framework library; Maki extends via Lua plugins).
        default:
            []
        }
    }

    static func supports(_ kind: SupportedAgentKind) -> Bool {
        !sources(for: kind).isEmpty
    }
}
