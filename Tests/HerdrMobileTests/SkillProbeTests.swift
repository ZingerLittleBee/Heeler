import Foundation
import Testing

@testable import HerdrMobile

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

    // MARK: command shape

    @Test func runsUnderPOSIXShell() {
        let command = SkillProbe.command(for: [projectSource, globalSource])
        #expect(command.hasPrefix("/bin/sh -c '"))
        #expect(command.hasSuffix(
            " herdr-skills-probe '/home/dev/repo/.claude/skills' '/home/dev/.claude/skills'"))
    }

    @Test func directoriesArePositionalArgumentsNotInterpolated() {
        let command = SkillProbe.command(for: [projectSource, globalSource])
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
                quotedDirectory: "'/home/dev/.codex/prompts'",
                layout: .markdownFiles)
        ])
        #expect(command.contains("for f in \"$1\"/*.md"))
    }

    @Test func scopeTravelsOnTheMarker() {
        let command = SkillProbe.command(for: [projectSource, globalSource])
        #expect(command.contains(SkillProbe.projectFileMarker))
        #expect(command.contains(SkillProbe.globalFileMarker))
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
                \(SkillProbe.projectFileMarker)/repo/.claude/skills/deploy/SKILL.md
                ---
                name: deploy
                ---
                \(SkillProbe.endMarker)
                \(SkillProbe.globalFileMarker)/home/.claude/skills/tdd/SKILL.md
                ---
                name: tdd
                ---
                \(SkillProbe.endMarker)
                """))
        #expect(files.count == 2)
        #expect(files[0].scope == .project)
        #expect(files[0].path == "/repo/.claude/skills/deploy/SKILL.md")
        #expect(files[0].content.contains("name: deploy"))
        #expect(files[1].scope == .global)
    }

    @Test func survivesCRLFFileContent() {
        let files = SkillProbe.probedFiles(
            in: output(
                "\(SkillProbe.projectFileMarker)/a/SKILL.md\n"
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
                \(SkillProbe.projectFileMarker)/a/SKILL.md
                content of a
                \(SkillProbe.projectFileMarker)/b/SKILL.md
                content of b
                \(SkillProbe.endMarker)
                """))
        // Entry /a never saw its end marker; only /b survives, uncorrupted.
        #expect(files.map(\.path) == ["/b/SKILL.md"])
        #expect(files[0].content == "content of b")
    }

    // MARK: full pipeline

    @Test func namesFallBackByLayout() {
        let skills = SkillProbe.skills(
            fromProbeOutput: output(
                """
                \(SkillProbe.projectFileMarker)/repo/.claude/skills/no-frontmatter/SKILL.md
                # Just a body
                \(SkillProbe.endMarker)
                \(SkillProbe.globalFileMarker)/home/.codex/prompts/fix-ci.md
                Fix the CI for me.
                \(SkillProbe.endMarker)
                """))
        #expect(skills.map(\.name) == ["no-frontmatter", "fix-ci"])
        #expect(skills[0].insertionText == "/no-frontmatter ")
    }

    @Test func projectShadowsSameNamedGlobal() {
        let skills = SkillProbe.skills(
            fromProbeOutput: output(
                """
                \(SkillProbe.projectFileMarker)/repo/.claude/skills/deploy/SKILL.md
                ---
                description: The project's own deploy.
                ---
                \(SkillProbe.endMarker)
                \(SkillProbe.globalFileMarker)/home/.claude/skills/deploy/SKILL.md
                ---
                description: The global deploy.
                ---
                \(SkillProbe.endMarker)
                """))
        #expect(skills.count == 1)
        #expect(skills[0].scope == .project)
        #expect(skills[0].description == "The project's own deploy.")
    }

    @Test func sortsProjectFirstThenAlphabetically() {
        let skills = SkillProbe.skills(
            fromProbeOutput: output(
                """
                \(SkillProbe.globalFileMarker)/home/.claude/skills/zeta/SKILL.md
                \(SkillProbe.endMarker)
                \(SkillProbe.globalFileMarker)/home/.claude/skills/Alpha/SKILL.md
                \(SkillProbe.endMarker)
                \(SkillProbe.projectFileMarker)/repo/.claude/skills/omega/SKILL.md
                \(SkillProbe.endMarker)
                """))
        #expect(skills.map(\.name) == ["omega", "Alpha", "zeta"])
    }

    @Test func unusableNamesAreSkipped() {
        let skills = SkillProbe.skills(
            fromProbeOutput: output(
                """
                \(SkillProbe.projectFileMarker)/repo/.claude/skills/has space/SKILL.md
                \(SkillProbe.endMarker)
                \(SkillProbe.projectFileMarker)/repo/.claude/skills/fine/SKILL.md
                ---
                name: also has spaces
                ---
                \(SkillProbe.endMarker)
                """))
        // The first entry's directory name cannot become one /word; the
        // second's frontmatter name is unusable but its directory rescues it.
        #expect(skills.map(\.name) == ["fine"])
    }

    @Test func descriptionsDropControlCharacters() {
        let skills = SkillProbe.skills(
            fromProbeOutput: output(
                """
                \(SkillProbe.projectFileMarker)/repo/.claude/skills/clean/SKILL.md
                ---
                description: "Safe\u{001B}[31m text"
                ---
                \(SkillProbe.endMarker)
                """))
        #expect(skills[0].description == "Safe[31m text")
    }
}
