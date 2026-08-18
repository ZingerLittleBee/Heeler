package dev.bybee.heeler.core.transport

/** One custom skill or slash command discovered for an Agent kind on a Host. */
data class AgentSkill(
    val scope: Scope,
    /** Callable name without its invocation prefix. */
    val name: String,
    /** Frontmatter description, if present. */
    val description: String?,
    /** `/`, `$`, or `/skill:` depending on the source. */
    val commandPrefix: String = "/",
    /** Remote path reported by the probe, fetched only on demand. */
    val path: String = "",
) {
    enum class Scope { PROJECT, GLOBAL }

    val command: String get() = commandPrefix + name
    val id: String get() = "${scope.name.lowercase()}|$command"
    /** What a keyboard inserts: never a submit byte. */
    val insertionText: String get() = "$command "
}

/** A compile-time source directory for one Agent kind's skills. */
data class SkillSource(
    val root: Root,
    /** Relative to [root], without a leading slash. */
    val relativePath: String,
    val layout: Layout,
    val commandPrefix: String = "/",
) {
    enum class Root { HOME, PROJECT }
    enum class Layout { SKILL_DIRECTORIES, MARKDOWN_FILES }
    val scope: AgentSkill.Scope get() =
        if (root == Root.PROJECT) AgentSkill.Scope.PROJECT else AgentSkill.Scope.GLOBAL
}

/**
 * The per-kind source table. Adding an Agent kind is data here; the probe,
 * parser, and UI all remain layout-driven. Project entries come first so they
 * shadow duplicate global commands, matching the Agents' precedence.
 */
object SkillSourceCatalog {
    fun sources(kind: SupportedAgentKind): List<SkillSource> = when (kind) {
        SupportedAgentKind.CLAUDE -> listOf(
            SkillSource(SkillSource.Root.PROJECT, ".claude/skills", SkillSource.Layout.SKILL_DIRECTORIES),
            SkillSource(SkillSource.Root.HOME, ".claude/skills", SkillSource.Layout.SKILL_DIRECTORIES),
        )
        SupportedAgentKind.CODEX -> listOf(
            SkillSource(SkillSource.Root.PROJECT, ".codex/skills", SkillSource.Layout.SKILL_DIRECTORIES, "$"),
            SkillSource(SkillSource.Root.PROJECT, ".agents/skills", SkillSource.Layout.SKILL_DIRECTORIES, "$"),
            SkillSource(SkillSource.Root.HOME, ".agents/skills", SkillSource.Layout.SKILL_DIRECTORIES, "$"),
            // Deprecated in Codex but still loaded by it.
            SkillSource(SkillSource.Root.HOME, ".codex/skills", SkillSource.Layout.SKILL_DIRECTORIES, "$"),
        )
        SupportedAgentKind.OPENCODE -> listOf(
            SkillSource(SkillSource.Root.PROJECT, ".opencode/commands", SkillSource.Layout.MARKDOWN_FILES),
            SkillSource(SkillSource.Root.PROJECT, ".opencode/command", SkillSource.Layout.MARKDOWN_FILES),
            SkillSource(SkillSource.Root.HOME, ".config/opencode/commands", SkillSource.Layout.MARKDOWN_FILES),
            SkillSource(SkillSource.Root.HOME, ".config/opencode/command", SkillSource.Layout.MARKDOWN_FILES),
        )
        SupportedAgentKind.PI -> listOf(
            SkillSource(SkillSource.Root.PROJECT, ".pi/skills", SkillSource.Layout.SKILL_DIRECTORIES, "/skill:"),
            SkillSource(SkillSource.Root.PROJECT, ".pi/skills", SkillSource.Layout.MARKDOWN_FILES, "/skill:"),
            SkillSource(SkillSource.Root.PROJECT, ".agents/skills", SkillSource.Layout.SKILL_DIRECTORIES, "/skill:"),
            SkillSource(SkillSource.Root.PROJECT, ".pi/prompts", SkillSource.Layout.MARKDOWN_FILES),
            SkillSource(SkillSource.Root.HOME, ".pi/agent/skills", SkillSource.Layout.SKILL_DIRECTORIES, "/skill:"),
            SkillSource(SkillSource.Root.HOME, ".pi/agent/skills", SkillSource.Layout.MARKDOWN_FILES, "/skill:"),
            SkillSource(SkillSource.Root.HOME, ".agents/skills", SkillSource.Layout.SKILL_DIRECTORIES, "/skill:"),
            SkillSource(SkillSource.Root.HOME, ".pi/agent/prompts", SkillSource.Layout.MARKDOWN_FILES),
        )
        else -> emptyList()
    }

    fun supports(kind: SupportedAgentKind): Boolean = sources(kind).isNotEmpty()
}

/**
 * One-round-trip skills probe. Marker framing makes login-shell chatter
 * harmless in exactly the same way as home-directory and Agent probes.
 */
object SkillProbe {
    const val FILE_MARKER_PREFIX = "__HEELER_SKILL_"
    const val END_MARKER = "__HEELER_SKILL_END__"
    /** Cap each frontmatter head so a directory of large skills cannot flood a channel. */
    const val MAXIMUM_BYTES_PER_FILE = 4_096
    const val MAXIMUM_BYTES_PER_DOCUMENT = 65_536

    data class ResolvedSource(
        val scope: AgentSkill.Scope,
        /** Already shell-quoted absolute directory. */
        val quotedDirectory: String,
        val layout: SkillSource.Layout,
        val commandPrefix: String = "/",
    )

    data class ProbedFile(val sourceIndex: Int, val path: String, val content: String)

    fun fileMarker(sourceIndex: Int): String = "$FILE_MARKER_PREFIX${sourceIndex}__="

    /**
     * A single `/bin/sh` command for every source. Directories are positional
     * arguments, never interpolated into the script body. Missing directories
     * are empty, not errors.
     */
    fun command(sources: List<ResolvedSource>): String {
        val loops = sources.mapIndexed { index, source ->
            "for f in \"\$${index + 1}\"${glob(source.layout)}; do " +
                "[ -f \"\$f\" ] || continue; " +
                "printf \"${fileMarker(index)}%s\\n\" \"\$f\"; " +
                "head -c $MAXIMUM_BYTES_PER_FILE \"\$f\"; " +
                "printf \"\\n$END_MARKER\\n\"; done"
        }
        return "/bin/sh -c '${loops.joinToString("; ")}; exit 0' herdr-skills-probe " +
            sources.joinToString(" ") { it.quotedDirectory }
    }

    /** Reads one reported document in full through the same marker framing. */
    fun readFileCommand(quotedPath: String): String =
        "/bin/sh -c '[ -f \"\$1\" ] || exit 0; " +
            "printf \"${fileMarker(0)}%s\\n\" \"\$1\"; " +
            "head -c $MAXIMUM_BYTES_PER_DOCUMENT \"\$1\"; " +
            "printf \"\\n$END_MARKER\\n\"' herdr-skill-read $quotedPath"

    fun documentContent(output: ByteArray): String? = probedFiles(output).firstOrNull()?.content

    /** Drops all lines outside begin/end frames as login-shell noise. */
    fun probedFiles(output: ByteArray): List<ProbedFile> {
        val files = mutableListOf<ProbedFile>()
        var current: MutableProbedFile? = null
        TerminalTextSafety.normalizingNewlines(output.decodeToString())
            .split('\n')
            .forEach { line ->
                val begin = beginEntry(line)
                when {
                    begin != null -> current = MutableProbedFile(begin.first, begin.second)
                    line == END_MARKER -> {
                        current?.let { files += ProbedFile(it.sourceIndex, it.path, it.lines.joinToString("\n")) }
                        current = null
                    }
                    else -> current?.lines?.add(line)
                }
            }
        return files
    }

    /**
     * Parses, derives names, drops unusable entries, shadows duplicate commands
     * in source order, then groups project skills before global skills and sorts
     * each scope alphabetically.
     */
    fun skills(output: ByteArray, sources: List<ResolvedSource>): List<AgentSkill> {
        val seenCommands = mutableSetOf<String>()
        return probedFiles(output).mapNotNull { file ->
            val source = sources.getOrNull(file.sourceIndex) ?: return@mapNotNull null
            val frontmatter = SkillFrontmatter.parse(file.content)
            val name = skillName(file, frontmatter) ?: return@mapNotNull null
            AgentSkill(source.scope, name, safeDescription(frontmatter.description), source.commandPrefix, file.path)
        }.filter { seenCommands.add(it.command) }
            .sortedWith(compareBy<AgentSkill>({ if (it.scope == AgentSkill.Scope.GLOBAL) 1 else 0 }, { it.name.lowercase() }))
    }

    private data class MutableProbedFile(
        val sourceIndex: Int,
        val path: String,
        val lines: MutableList<String> = mutableListOf(),
    )

    private fun glob(layout: SkillSource.Layout): String = when (layout) {
        SkillSource.Layout.SKILL_DIRECTORIES -> "/*/SKILL.md"
        SkillSource.Layout.MARKDOWN_FILES -> "/*.md"
    }

    private fun beginEntry(line: String): Pair<Int, String>? {
        if (!line.startsWith(FILE_MARKER_PREFIX)) return null
        val rest = line.removePrefix(FILE_MARKER_PREFIX)
        val separator = rest.indexOf("__=")
        if (separator <= 0) return null
        val index = rest.substring(0, separator).toIntOrNull()?.takeIf { it >= 0 } ?: return null
        return index to rest.substring(separator + 3)
    }

    private fun skillName(file: ProbedFile, frontmatter: SkillFrontmatter): String? {
        frontmatter.name?.takeIf(::isUsableName)?.let { return it }
        val parts = file.path.split('/').filter(String::isNotEmpty)
        val candidate = if (parts.lastOrNull() == "SKILL.md") {
            parts.dropLast(1).lastOrNull()
        } else {
            parts.lastOrNull()?.removeSuffix(".md")
        }
        return candidate?.takeIf(::isUsableName)
    }

    private fun isUsableName(name: String): Boolean =
        name.isNotEmpty() && name.length <= 100 && name.none(Char::isWhitespace) &&
            TerminalTextSafety.containsOnlySafeScalars(name)

    private fun safeDescription(description: String?): String? = description
        ?.filter { it == ' ' || it == '\t' || it == '\n' || !it.isISOControl() }
        ?.trim()
        ?.takeIf(String::isNotEmpty)
}

/** Lenient YAML-subset frontmatter parser for remote-authored skill documents. */
data class SkillFrontmatter(val name: String? = null, val description: String? = null) {
    companion object {
        fun parse(content: String): SkillFrontmatter {
            var lines = TerminalTextSafety.normalizingNewlines(content).split('\n').toMutableList()
            if (lines.firstOrNull()?.startsWith('\ufeff') == true) {
                lines[0] = lines[0].removePrefix("\ufeff")
            }
            while (lines.firstOrNull()?.trim()?.isEmpty() == true) lines.removeAt(0)
            if (lines.firstOrNull()?.trim() != "---") return SkillFrontmatter()

            val fields = mutableMapOf<String, String>()
            var currentKey: String? = null
            var blockStyle: BlockStyle? = null
            val blockLines = mutableListOf<String>()

            fun finishCurrent() {
                val key = currentKey ?: return
                blockStyle?.let { style ->
                    fields[key] = blockLines.joinToString(if (style == BlockStyle.LITERAL) "\n" else " ").trim()
                }
                currentKey = null
                blockStyle = null
                blockLines.clear()
            }

            for (line in lines.drop(1)) {
                val trimmed = line.trim()
                if (trimmed == "---" || trimmed == "...") break
                val field = topLevelField(line)
                when {
                    field != null -> {
                        finishCurrent()
                        currentKey = field.first
                        blockStyle = BlockStyle.fromIndicator(field.second)
                        if (blockStyle == null) fields[field.first] = unquote(field.second)
                    }
                    currentKey != null && line.firstOrNull()?.isWhitespace() == true -> {
                        if (blockStyle != null) {
                            blockLines += trimmed
                        } else if (trimmed.isNotEmpty()) {
                            fields[currentKey!!] = listOfNotNull(fields[currentKey!!], trimmed).joinToString(" ")
                        }
                    }
                }
            }
            finishCurrent()
            return SkillFrontmatter(fields["name"]?.trim()?.takeIf(String::isNotEmpty), fields["description"]?.trim()?.takeIf(String::isNotEmpty))
        }

        private enum class BlockStyle { LITERAL, FOLDED;
            companion object {
                fun fromIndicator(indicator: String): BlockStyle? = when {
                    indicator.firstOrNull() == '|' && indicator.length <= 2 -> LITERAL
                    indicator.firstOrNull() == '>' && indicator.length <= 2 -> FOLDED
                    else -> null
                }
            }
        }

        private fun topLevelField(line: String): Pair<String, String>? {
            if (line.firstOrNull()?.isWhitespace() == true) return null
            val colon = line.indexOf(':')
            if (colon <= 0) return null
            val key = line.substring(0, colon)
            if (!key.all { it.isLetterOrDigit() || it == '_' || it == '-' }) return null
            return key to line.substring(colon + 1).trim()
        }

        private fun unquote(value: String): String = when {
            value.length >= 2 && value.first() == '"' && value.last() == '"' ->
                value.drop(1).dropLast(1).replace("\\\"", "\"")
            value.length >= 2 && value.first() == '\'' && value.last() == '\'' ->
                value.drop(1).dropLast(1).replace("''", "'")
            else -> value
        }
    }
}

/** Terminal-safe text helpers shared by remote-authored skill parsing. */
object TerminalTextSafety {
    fun containsOnlySafeScalars(text: String): Boolean = text.all { character ->
        character == '\t' || character == '\n' || character == '\r' || !character.isISOControl()
    }

    fun normalizingNewlines(text: String): String = text.replace("\r\n", "\n").replace('\r', '\n')
}
