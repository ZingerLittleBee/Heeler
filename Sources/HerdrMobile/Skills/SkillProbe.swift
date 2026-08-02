import Foundation

/// The one-round-trip skills probe: builds the exec command that walks a
/// kind's source directories and parses its marker-framed output back into
/// `AgentSkill`s. Markers keep login-shell noise harmless, exactly like the
/// socat and agent-availability probes.
enum SkillProbe {
    static let projectFileMarker = "__HERDR_MOBILE_SKILL_P__="
    static let globalFileMarker = "__HERDR_MOBILE_SKILL_G__="
    static let endMarker = "__HERDR_MOBILE_SKILL_END__"
    /// Frontmatter lives at the top of the file; capping the read keeps a
    /// directory full of large skills from flooding the channel.
    static let maximumBytesPerFile = 4096

    /// A source resolved against this Host: scope plus the already-quoted
    /// absolute directory (`RemoteShellPath.quotedAbsolute` output).
    struct ResolvedSource: Sendable, Equatable {
        let scope: AgentSkill.Scope
        let quotedDirectory: String
        let layout: SkillSource.Layout
    }

    /// One `/bin/sh` command covering every source. Directories are passed as
    /// positional arguments so no path is interpolated into the script body;
    /// the glob patterns are compile-time constants from the layout. Always
    /// exits 0 — a missing directory is an empty pane, not an error.
    static func command(for sources: [ResolvedSource]) -> String {
        let loops = sources.enumerated().map { index, source in
            let argument = "$\(index + 1)"
            let marker =
                source.scope == .project ? projectFileMarker : globalFileMarker
            return "for f in \"\(argument)\"\(glob(for: source.layout)); do "
                + "[ -f \"$f\" ] || continue; "
                + "printf \"\(marker)%s\\n\" \"$f\"; "
                + "head -c \(maximumBytesPerFile) \"$f\"; "
                + "printf \"\\n\(endMarker)\\n\"; done"
        }
        let script = loops.joined(separator: "; ") + "; exit 0"
        let arguments = sources.map(\.quotedDirectory).joined(separator: " ")
        return "/bin/sh -c '\(script)' herdr-skills-probe \(arguments)"
    }

    private static func glob(for layout: SkillSource.Layout) -> String {
        switch layout {
        case .skillDirectories: "/*/SKILL.md"
        case .markdownFiles: "/*.md"
        }
    }

    /// One file the probe printed: where it was found and what its head
    /// contained.
    struct ProbedFile: Equatable, Sendable {
        let scope: AgentSkill.Scope
        let path: String
        let content: String
    }

    /// Splits marker-framed probe output back into files. Lines outside a
    /// begin/end pair are login-shell noise and are dropped; a begin marker
    /// inside a file's own content starts a fresh entry rather than
    /// corrupting the current one.
    static func probedFiles(in output: Data) -> [ProbedFile] {
        var files: [ProbedFile] = []
        var current: (scope: AgentSkill.Scope, path: String, lines: [Substring])?

        // CRLF first: "\r\n" is a single grapheme cluster in Swift, so a
        // split on "\n" would leave a CRLF-authored file's lines glued to
        // the markers around them.
        for line in TerminalTextSafety.normalizingNewlines(
            String(decoding: output, as: UTF8.self))
            .split(separator: "\n", omittingEmptySubsequences: false)
        {
            if let entry = beginEntry(line) {
                current = (entry.scope, entry.path, [])
            } else if line == endMarker {
                if let current {
                    files.append(
                        ProbedFile(
                            scope: current.scope,
                            path: current.path,
                            content: current.lines.joined(separator: "\n")))
                }
                current = nil
            } else {
                current?.lines.append(line)
            }
        }
        return files
    }

    private static func beginEntry(
        _ line: Substring
    ) -> (scope: AgentSkill.Scope, path: String)? {
        if line.hasPrefix(projectFileMarker) {
            return (.project, String(line.dropFirst(projectFileMarker.count)))
        }
        if line.hasPrefix(globalFileMarker) {
            return (.global, String(line.dropFirst(globalFileMarker.count)))
        }
        return nil
    }

    /// The full pipeline: parse the output, name each file by its layout,
    /// drop unusable names, shadow duplicates in probe order (project sources
    /// run first, so a project skill wins over a same-named global one), and
    /// sort each scope alphabetically.
    static func skills(fromProbeOutput output: Data) -> [AgentSkill] {
        var seenNames: Set<String> = []
        var skills: [AgentSkill] = []
        for file in probedFiles(in: output) {
            let frontmatter = SkillFrontmatter.parse(file.content)
            guard let name = skillName(for: file, frontmatter: frontmatter) else {
                continue
            }
            guard seenNames.insert(name).inserted else { continue }
            skills.append(
                AgentSkill(
                    scope: file.scope,
                    name: name,
                    description: safeDescription(frontmatter.description)))
        }
        return skills.sorted {
            ($0.scope == .global ? 1 : 0, $0.name.lowercased())
                < ($1.scope == .global ? 1 : 0, $1.name.lowercased())
        }
    }

    /// Frontmatter name first, then the layout-derived fallback: the parent
    /// directory for `SKILL.md` files, the filename stem otherwise.
    private static func skillName(
        for file: ProbedFile, frontmatter: SkillFrontmatter
    ) -> String? {
        if let name = frontmatter.name, isUsableName(name) { return name }
        let components = file.path.split(separator: "/")
        let fallback: Substring?
        if components.last == "SKILL.md" {
            fallback = components.dropLast().last
        } else {
            fallback = components.last.map { $0.hasSuffix(".md") ? $0.dropLast(3) : $0 }
        }
        guard let fallback, isUsableName(String(fallback)) else { return nil }
        return String(fallback)
    }

    /// A name becomes terminal input, so it must survive as one `/word`:
    /// non-empty, reasonably short, no whitespace, no control characters.
    private static func isUsableName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 100
            && !name.contains(where: \.isWhitespace)
            && TerminalTextSafety.containsOnlySafeScalars(name)
    }

    /// Descriptions are display-only; control characters are dropped rather
    /// than trusted, and an empty result reads as "no description".
    private static func safeDescription(_ description: String?) -> String? {
        guard let description else { return nil }
        var scalars = String.UnicodeScalarView()
        scalars.append(
            contentsOf: description.unicodeScalars.filter {
                $0 == " " || $0 == "\t" || $0 == "\n"
                    || $0.properties.generalCategory != .control
            })
        let cleaned = String(scalars)
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
