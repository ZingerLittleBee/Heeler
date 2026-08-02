import Foundation
import Testing

@testable import Heeler

// The probe command's shape and output parsing, pinned without sshd (the
// SocatDiscoveryTests precedent): CI provisions no SSH server, so the
// command's wire shape and the parser are what unit tests can hold still.
@Suite("skills probe")
struct SkillProbeTests {
    private let projectSource = SkillProbe.ResolvedSource(
        scope: .project,
        quotedDirectory: "'/home/dev/repo/.claude/skills'",
        layout: .skillDirectories)
    private let globalSource = SkillProbe.ResolvedSource(
        scope: .global,
        quotedDirectory: "'/home/dev/.claude/skills'",
        layout: .skillDirectories)

    private var claudeSources: [SkillProbe.ResolvedSource] {
        [projectSource, globalSource]
    }

    private func marker(_ index: Int) -> String {
        SkillProbe.fileMarker(sourceIndex: index)
    }

    // MARK: command shape

    @Test func runsUnderPOSIXShell() {
        let command = SkillProbe.command(for: claudeSources)
        #expect(command.hasPrefix("/bin/sh -c '"))
        #expect(command.hasSuffix(
            " herdr-skills-probe '/home/dev/repo/.claude/skills' '/home/dev/.claude/skills'"))
    }

    @Test func directoriesArePositionalArgumentsNotInterpolated() {
        let command = SkillProbe.command(for: claudeSources)
        // The script body references "$1"/"$2"; the paths appear only in the
        // trailing argument list.
        #expect(command.contains("for f in \"$1\"/*/SKILL.md"))
        #expect(command.contains("for f in \"$2\"/*/SKILL.md"))
        let script = command.split(separator: "'", maxSplits: 2)[1]
        #expect(!script.contains("/home/dev"))
    }

    @Test func markdownFileLayoutGlobsFlatFiles() {
        let command = SkillProbe.command(for: [
            SkillProbe.ResolvedSource(
                scope: .global,
                quotedDirectory: "'/home/dev/.pi/agent/prompts'",
                layout: .markdownFiles)
        ])
        #expect(command.contains("for f in \"$1\"/*.md"))
    }

    @Test func sourceIndexTravelsOnTheMarker() {
        let command = SkillProbe.command(for: claudeSources)
        #expect(command.contains(marker(0)))
        #expect(command.contains(marker(1)))
    }

    @Test func capsPerFileReadAndAlwaysExitsZero() {
        let command = SkillProbe.command(for: [projectSource])
        #expect(command.contains("head -c \(SkillProbe.maximumBytesPerFile)"))
        #expect(command.contains("; exit 0'"))
    }

    // MARK: output parsing

    private func output(_ text: String) -> Data {
        Data(text.utf8)
    }

    @Test func parsesMarkerFramedFiles() {
        let files = SkillProbe.probedFiles(
            in: output(
                """
                Welcome to fish, the friendly interactive shell
                \(marker(0))/repo/.claude/skills/deploy/SKILL.md
                ---
                name: deploy
                ---
                \(SkillProbe.endMarker)
                \(marker(1))/home/.claude/skills/tdd/SKILL.md
                ---
                name: tdd
                ---
                \(SkillProbe.endMarker)
                """))
        #expect(files.count == 2)
        #expect(files[0].sourceIndex == 0)
        #expect(files[0].path == "/repo/.claude/skills/deploy/SKILL.md")
        #expect(files[0].content.contains("name: deploy"))
        #expect(files[1].sourceIndex == 1)
    }

    @Test func survivesCRLFFileContent() {
        let files = SkillProbe.probedFiles(
            in: output(
                "\(marker(0))/a/SKILL.md\n"
                    + "---\r\nname: crlf\r\n---\r\n"
                    + "\(SkillProbe.endMarker)\n"))
        #expect(files.count == 1)
        #expect(SkillFrontmatter.parse(files[0].content).name == "crlf")
    }

    @Test func noiseOutsideMarkersIsDropped() {
        let files = SkillProbe.probedFiles(
            in: output("motd noise\nmore noise\n\(SkillProbe.endMarker)\n"))
        #expect(files.isEmpty)
    }

    @Test func beginMarkerInsideContentStartsAFreshEntry() {
        let files = SkillProbe.probedFiles(
            in: output(
                """
                \(marker(0))/a/SKILL.md
                content of a
                \(marker(0))/b/SKILL.md
                content of b
                \(SkillProbe.endMarker)
                """))
        // Entry /a never saw its end marker; only /b survives, uncorrupted.
        #expect(files.map(\.path) == ["/b/SKILL.md"])
        #expect(files[0].content == "content of b")
    }

    // MARK: full pipeline

    @Test func namesFallBackByLayout() {
        let sources = [
            projectSource,
            SkillProbe.ResolvedSource(
                scope: .global,
                quotedDirectory: "'/home/.pi/agent/prompts'",
                layout: .markdownFiles),
        ]
        let skills = SkillProbe.skills(
            fromProbeOutput: output(
                """
                \(marker(0))/repo/.claude/skills/no-frontmatter/SKILL.md
                # Just a body
                \(SkillProbe.endMarker)
                \(marker(1))/home/.pi/agent/prompts/fix-ci.md
                Fix the CI for me.
                \(SkillProbe.endMarker)
                """),
            sources: sources)
        #expect(skills.map(\.name) == ["no-frontmatter", "fix-ci"])
        #expect(skills[0].insertionText == "/no-frontmatter ")
        // The path travels with the skill so View Content can fetch it later.
        #expect(skills[0].path == "/repo/.claude/skills/no-frontmatter/SKILL.md")
    }

    // MARK: single-document read

    @Test func readFileCommandIsMarkerFramedAndCapped() {
        let command = SkillProbe.readFileCommand(
            quotedPath: "'/repo/.claude/skills/deploy/SKILL.md'")
        #expect(command.hasPrefix("/bin/sh -c '"))
        #expect(command.hasSuffix(" herdr-skill-read '/repo/.claude/skills/deploy/SKILL.md'"))
        #expect(command.contains("head -c \(SkillProbe.maximumBytesPerDocument)"))
        // A missing file prints no marker at all — absence, not emptiness.
        #expect(command.contains("[ -f \"$1\" ] || exit 0"))
    }

    @Test func documentContentComesBackFramed() {
        let framed = output(
            """
            login shell noise
            \(marker(0))/repo/.claude/skills/deploy/SKILL.md
            ---
            name: deploy
            ---
            The whole body.
            \(SkillProbe.endMarker)
            """)
        #expect(
            SkillProbe.documentContent(in: framed)
                == "---\nname: deploy\n---\nThe whole body.")
        #expect(SkillProbe.documentContent(in: output("nothing but noise\n")) == nil)
    }

    @Test func commandPrefixRidesTheSource() {
        let sources = [
            SkillProbe.ResolvedSource(
                scope: .global,
                quotedDirectory: "'/home/.agents/skills'",
                layout: .skillDirectories,
                commandPrefix: "$"),
            SkillProbe.ResolvedSource(
                scope: .global,
                quotedDirectory: "'/home/.pi/agent/skills'",
                layout: .skillDirectories,
                commandPrefix: "/skill:"),
        ]
        let skills = SkillProbe.skills(
            fromProbeOutput: output(
                """
                \(marker(0))/home/.agents/skills/plan/SKILL.md
                \(SkillProbe.endMarker)
                \(marker(1))/home/.pi/agent/skills/pdf-tools/SKILL.md
                \(SkillProbe.endMarker)
                """),
            sources: sources)
        // Alphabetical within the scope: pdf-tools sorts before plan.
        #expect(skills.map(\.command) == ["/skill:pdf-tools", "$plan"])
        #expect(skills.map(\.insertionText) == ["/skill:pdf-tools ", "$plan "])
    }

    @Test func projectShadowsSameNamedGlobal() {
        let skills = SkillProbe.skills(
            fromProbeOutput: output(
                """
                \(marker(0))/repo/.claude/skills/deploy/SKILL.md
                ---
                description: The project's own deploy.
                ---
                \(SkillProbe.endMarker)
                \(marker(1))/home/.claude/skills/deploy/SKILL.md
                ---
                description: The global deploy.
                ---
                \(SkillProbe.endMarker)
                """),
            sources: claudeSources)
        #expect(skills.count == 1)
        #expect(skills[0].scope == .project)
        #expect(skills[0].description == "The project's own deploy.")
    }

    @Test func sortsProjectFirstThenAlphabetically() {
        let skills = SkillProbe.skills(
            fromProbeOutput: output(
                """
                \(marker(1))/home/.claude/skills/zeta/SKILL.md
                \(SkillProbe.endMarker)
                \(marker(1))/home/.claude/skills/Alpha/SKILL.md
                \(SkillProbe.endMarker)
                \(marker(0))/repo/.claude/skills/omega/SKILL.md
                \(SkillProbe.endMarker)
                """),
            sources: claudeSources)
        #expect(skills.map(\.name) == ["omega", "Alpha", "zeta"])
    }

    @Test func unusableNamesAndUnknownSourceIndexesAreSkipped() {
        let skills = SkillProbe.skills(
            fromProbeOutput: output(
                """
                \(marker(0))/repo/.claude/skills/has space/SKILL.md
                \(SkillProbe.endMarker)
                \(marker(0))/repo/.claude/skills/fine/SKILL.md
                ---
                name: also has spaces
                ---
                \(SkillProbe.endMarker)
                \(marker(9))/elsewhere/thing/SKILL.md
                \(SkillProbe.endMarker)
                """),
            sources: claudeSources)
        // The first entry's directory name cannot become one word; the
        // second's frontmatter name is unusable but its directory rescues
        // it; the third names a source that was never sent.
        #expect(skills.map(\.name) == ["fine"])
    }

    @Test func descriptionsDropControlCharacters() {
        let skills = SkillProbe.skills(
            fromProbeOutput: output(
                """
                \(marker(0))/repo/.claude/skills/clean/SKILL.md
                ---
                description: "Safe\u{001B}[31m text"
                ---
                \(SkillProbe.endMarker)
                """),
            sources: claudeSources)
        #expect(skills[0].description == "Safe[31m text")
    }

    // MARK: source catalog

    @Test func catalogCoversExactlyTheResearchedKinds() {
        let supported = SupportedAgentKind.allCases.filter(SkillSourceCatalog.supports)
        #expect(supported == [.pi, .claude, .codex, .opencode])
    }

    @Test func projectSourcesComeFirstForEveryKind() {
        for kind in SupportedAgentKind.allCases {
            let sources = SkillSourceCatalog.sources(for: kind)
            // Dedupe order is probe order, so a global source before a
            // project one would invert shadowing.
            if let firstGlobal = sources.firstIndex(where: { $0.root == .home }) {
                #expect(
                    sources[firstGlobal...].allSatisfy { $0.root == .home },
                    "kind \(kind) interleaves project and global sources")
            }
        }
    }

    @Test func codexUsesTheMentionPrefix() {
        let sources = SkillSourceCatalog.sources(for: .codex)
        #expect(!sources.isEmpty)
        #expect(sources.allSatisfy { $0.commandPrefix == "$" })
    }
}
