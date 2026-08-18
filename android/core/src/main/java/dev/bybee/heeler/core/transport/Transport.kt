package dev.bybee.heeler.core.transport

import dev.bybee.heeler.core.notifications.NotificationRegistrationError
import dev.bybee.heeler.core.wire.AgentInfo
import dev.bybee.heeler.core.wire.AgentReadParams
import dev.bybee.heeler.core.wire.AgentRenameParams
import dev.bybee.heeler.core.wire.AgentPromptParams
import dev.bybee.heeler.core.wire.AgentSendKeysParams
import dev.bybee.heeler.core.wire.AgentStatus
import dev.bybee.heeler.core.wire.PaneReadParams
import dev.bybee.heeler.core.wire.PaneReadResult
import dev.bybee.heeler.core.wire.PaneTarget
import dev.bybee.heeler.core.wire.SessionSnapshot
import dev.bybee.heeler.core.wire.WorkspaceRenameParams
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.io.File

/**
 * The app-side abstraction that executes herdr API requests over SSH. UI code
 * talks to Transport, never to SSH primitives (ADR 0011).
 */
interface Transport {
    /**
     * Verifies a supported protocol and returns server identity. This must be
     * the first herdr API call on every new connection path; Host-local session
     * discovery may run before it.
     */
    suspend fun ping(): ServerInfo

    /**
     * Lists herdr sessions visible to this SSH account. This is Host-level and
     * does not depend on the selected API socket, so onboarding can recover
     * from a stale manual selection.
     */
    suspend fun listSessions(): List<HerdrSession> = emptyList()

    /** Lists Agents herdr detected across all workspaces. */
    suspend fun listAgents(): List<Agent>

    /**
     * Lists supported Agent kinds whose canonical executables are available on
     * this Host. Alternative transports report no detected kinds by default.
     */
    suspend fun availableAgentKinds(): List<SupportedAgentKind> = emptyList()

    /**
     * The full session tree in one call: agents plus workspace labels and
     * worktrees. The Console snapshot source, re-fetched on every events
     * session connection.
     */
    suspend fun sessionSnapshot(): SessionSnapshot

    /** Reads a Pane's recent terminal output for a Console card snippet. */
    suspend fun readPane(params: PaneReadParams): PaneReadResult

    /**
     * Reads an Agent's terminal output. Unlike `pane.read`, this preserves
     * alternate-screen history semantics: history-capable sources fail honestly
     * while an Agent works instead of silently degrading to visible screen.
     */
    suspend fun readAgent(params: AgentReadParams): PaneReadResult

    /**
     * Delivers one complete local draft through `agent.prompt`. It deliberately
     * omits `wait`: the response acknowledges delivery into the Agent pane;
     * Agent Status events report subsequent work.
     */
    suspend fun promptAgent(params: AgentPromptParams): Agent

    /** Sends control keys to an Agent (`agent.send_keys`). */
    suspend fun sendAgentKeys(params: AgentSendKeysParams)

    /**
     * Starts a fresh Agent by creating a tab in the selected workspace, then
     * starting the requested kind in its root Pane. Membership surfaces through
     * normal snapshot/delta machinery, so callers do not mutate lists directly.
     */
    suspend fun startAgent(request: AgentLaunchRequest): Agent

    /**
     * Starts an Agent in a fresh git worktree. `worktree.create` resolves from
     * the source workspace cwd and returns a workspace whose root Pane already
     * runs a shell, so this skips `tab.create`; the `agent_pane_busy` readiness
     * retry still applies.
     */
    suspend fun startAgentInNewWorktree(request: AgentLaunchRequest, worktree: WorktreeSpec): Agent

    /** Closes a Pane. Its membership removal reaches callers through snapshots/events. */
    suspend fun closePane(params: PaneTarget)

    /**
     * Renames an Agent. A null name clears its custom name; herdr rejects a
     * non-null value outside `^[a-z][a-z0-9_-]{0,31}$` with
     * `invalid_agent_name`. Rename events do not carry the new agent name, so
     * consumers re-snapshot after this call rather than mutating local state.
     */
    suspend fun renameAgent(params: AgentRenameParams)

    /**
     * Renames a workspace. herdr accepts any label, including whitespace or
     * empty labels; callers rely on `workspace.renamed` rather than local edits.
     */
    suspend fun renameWorkspace(params: WorkspaceRenameParams)

    /**
     * Opens the Host's one dedicated long-lived events channel. `end()` closes
     * it explicitly. Replayed events on subscription are ordinary change
     * signals, never state: callers still fetch a snapshot alongside it.
     */
    suspend fun subscribeToEvents(subscriptions: List<EventSubscription>): HerdrEventStream

    /**
     * Opens the Host's dedicated PTY running `herdr agent attach`. Exactly one
     * terminal channel is allowed per Host.
     */
    suspend fun attachTerminal(request: TerminalAttachRequest): TerminalAttachSession

    /**
     * Stages one normalized app-owned image in private Host temporary storage.
     * Concrete transports own destination selection, restrictive permissions,
     * partial-file handling, and atomic completion (ADR 0006).
     */
    suspend fun stageImage(
        image: PreparedImage,
        progress: suspend (AttachmentStageProgress) -> Unit,
    ): StagedImage = throw AttachmentStagingError.SftpUnavailable

    /** Stages one app-owned file under the same SFTP/permission/atomic policy. */
    suspend fun stageFile(
        file: PreparedFile,
        progress: suspend (AttachmentStageProgress) -> Unit,
    ): StagedFile = throw AttachmentStagingError.SftpUnavailable

    /**
     * Reads the Heeler plugin's notification registration file, returning null
     * when no device has registered. Plugin absence throws
     * [NotificationRegistrationError.PluginNotInstalled] rather than masking
     * installation state as a broken read.
     */
    suspend fun readNotificationRegistration(): ByteArray? =
        throw NotificationRegistrationError.PluginNotInstalled

    /** Atomically replaces the plugin registration file (temp + rename). */
    suspend fun replaceNotificationRegistration(contents: ByteArray) {
        throw NotificationRegistrationError.PluginNotInstalled
    }

    /** Reads the plugin's optional `notify.json` config file. */
    suspend fun readNotificationConfig(): ByteArray? =
        throw NotificationRegistrationError.PluginNotInstalled

    /** Atomically replaces the plugin's optional `notify.json` config file. */
    suspend fun replaceNotificationConfig(contents: ByteArray) {
        throw NotificationRegistrationError.PluginNotInstalled
    }

    /**
     * Lists custom slash commands for an Agent kind. SSH implementations probe
     * the remote filesystem; alternative transports report no skills by default.
     */
    suspend fun listSkills(query: SkillListQuery): List<AgentSkill> = emptyList()

    /** Reads one reported skill document in full, subject to the remote cap. */
    suspend fun readSkillFile(path: String): String =
        throw TransportError.ChannelFailed("This transport cannot read skill files.")

    /** Whether the underlying Host connection is alive. */
    suspend fun isConnected(): Boolean

    /** Explicit terminal teardown. A closed Transport is not reusable. */
    suspend fun close()
}

/** The interactive Agent kinds supported by herdr protocol 17. */
enum class SupportedAgentKind(
    val rawValue: String,
    val displayName: String,
    val executable: String = rawValue,
) {
    PI("pi", "Pi"),
    CLAUDE("claude", "Claude Code"),
    CODEX("codex", "Codex"),
    GEMINI("gemini", "Gemini CLI"),
    CURSOR("cursor", "Cursor Agent", "cursor-agent"),
    DEVIN("devin", "Devin CLI"),
    ANTIGRAVITY("agy", "Antigravity"),
    CLINE("cline", "Cline"),
    OMP("omp", "OMP"),
    MASTRACODE("mastracode", "Mastra Code"),
    OPENCODE("opencode", "OpenCode"),
    COPILOT("copilot", "GitHub Copilot CLI"),
    KIMI("kimi", "Kimi CLI"),
    KIRO("kiro", "Kiro CLI", "kiro-cli"),
    DROID("droid", "Droid"),
    AMP("amp", "Amp"),
    GROK("grok", "Grok Build"),
    HERMES("hermes", "Hermes Agent"),
    KILO("kilo", "Kilo Code"),
    QODERCLI("qodercli", "Qoder CLI"),
    MAKI("maki", "Maki"),
    ;

    companion object {
        fun fromRawValue(rawValue: String): SupportedAgentKind? =
            entries.firstOrNull { it.rawValue == rawValue }
    }
}

/**
 * App-domain request for launching a fresh coding Agent.
 *
 * herdr protocol 17 split the old topology-changing `agent.start` into
 * `tab.create` followed by pane-targeted `agent.start`. Keeping that wire
 * choreography behind [Transport] prevents UI code from depending on the
 * server's transport-level request shapes.
 */
data class AgentLaunchRequest(
    val kind: String,
    val name: String,
    val arguments: List<String> = emptyList(),
    val workspaceID: String? = null,
    /**
     * Working directory for the fresh tab, carried when a launch starts from
     * another Agent screen and should land in the same place. Null lets herdr
     * fall back to the workspace directory.
     */
    val cwd: String? = null,
)

/**
 * What the skills probe needs: the Agent kind and its launch project root.
 * The root is the worktree checkout or Agent start directory, deliberately
 * not the foreground cwd: an Agent changing directories cannot alter skills.
 */
data class SkillListQuery(
    val kind: SupportedAgentKind,
    /** Null skips project skills when the Agent's project is unknown. */
    val projectRoot: String? = null,
)

/**
 * App-domain refinements for a fresh-worktree launch. Null fields use herdr's
 * defaults: a generated `worktree/<name>` branch from HEAD in herdr's root.
 */
data class WorktreeSpec(val branch: String? = null, val base: String? = null)

/**
 * herdr server identity reported by `ping`. A protocol newer than this
 * generated snapshot remains usable; newer additive features are advisory.
 */
data class ServerInfo(
    val version: String,
    val protocolVersion: Int,
    /** Advisory only: this Host is newer than the schema snapshot. */
    val exceedsGeneratedProtocol: Boolean = false,
)

/** One entry from `herdr session list --json` on a Host. */
@Serializable
data class HerdrSession(
    val name: String,
    @SerialName("default") val isDefault: Boolean,
    @SerialName("running") val isRunning: Boolean,
)

/**
 * The grammar herdr 0.7.4 enforces for named sessions. Keeping it at the
 * transport boundary prevents malformed discovery output from entering a
 * remote socket path; forms reuse it for immediate feedback.
 */
object HerdrSessionName {
    const val MAXIMUM_UTF8_LENGTH = 64

    fun isValid(name: String): Boolean =
        name.isNotEmpty() && name != "." && name != ".." &&
            name.encodeToByteArray().size <= MAXIMUM_UTF8_LENGTH &&
            name.all { character ->
                character in '0'..'9' || character in 'A'..'Z' ||
                    character in 'a'..'z' || character == '.' ||
                    character == '_' || character == '-'
            }
}

/**
 * Paths interpolated into the Host login shell use the conservative quoting
 * subset shared by POSIX shells and fish. Spaces are safe in single quotes;
 * quote, backslash, and control characters are refused because their quote
 * behavior differs across those shells.
 */
object RemoteShellPath {
    fun quotedAbsolute(path: String): String? =
        path.takeIf(::isQuotableAbsolute)?.let { "'$it'" }

    fun isQuotableAbsolute(path: String): Boolean =
        path.startsWith('/') && path.all { scalar ->
            scalar.code >= 0x20 && scalar.code != 0x7f && scalar != '\'' && scalar != '\\'
        }
}

/** A coding Agent process running inside a herdr Pane. */
data class Agent(
    val terminalID: String,
    val kind: String,
    val name: String?,
    val title: String,
    var status: AgentStatus,
    val workspaceID: String,
    val tabID: String,
    val paneID: String,
    val cwd: String,
    val revision: Int,
) {
    /** The server name when present, otherwise the detected kind. */
    val displayName: String get() = name ?: kind

    companion object {
        /**
         * Maps a generated [AgentInfo] into the domain view. Wire-optional
         * fields degrade instead of failing: herdr has no stability guarantee,
         * and a missing title must not drop an Agent from the list.
         */
        fun fromWire(info: AgentInfo): Agent = Agent(
            terminalID = info.terminalID,
            kind = info.agent ?: "unknown",
            name = info.displayAgent.nonEmpty() ?: info.name.nonEmpty(),
            title = info.terminalTitleStripped ?: info.terminalTitle ?: "",
            status = info.agentStatus,
            workspaceID = info.workspaceID,
            tabID = info.tabID,
            paneID = info.paneID,
            cwd = info.cwd.orEmpty(),
            revision = info.revision,
        )
    }
}

/** Where the herdr API socket lives on a Host. */
sealed interface HerdrSocketLocation {
    /** The default `~/.config/herdr/herdr.sock`. */
    data object DefaultSession : HerdrSocketLocation

    /** The named `~/.config/herdr/sessions/<name>/herdr.sock`. */
    data class NamedSession(val name: String) : HerdrSocketLocation {
        init {
            require(HerdrSessionName.isValid(name)) { "Invalid herdr session name." }
        }
    }

    /** An absolute path known in advance and needing no remote-home resolution. */
    data class AbsolutePath(val path: String) : HerdrSocketLocation

    /** Resolves a home-relative location to an absolute socket path. */
    fun path(homeDirectory: String): String {
        val home = homeDirectory.removeSuffix("/")
        return when (this) {
            DefaultSession -> "$home/.config/herdr/herdr.sock"
            is NamedSession -> "$home/.config/herdr/sessions/$name/herdr.sock"
            is AbsolutePath -> path
        }
    }
}

/** App-owned normalized image ready for transport; local naming carries no source metadata. */
data class PreparedImage(
    val file: File,
    val format: PreparedImageFormat,
    val pixelWidth: Int,
    val pixelHeight: Int,
    val byteCount: Long,
) {
    companion object {
        const val MAXIMUM_ENCODED_BYTE_COUNT = 16 * 1024 * 1024
    }
}

enum class PreparedImageFormat(val fileExtension: String) {
    JPEG("jpg"),
    PNG("png"),
}

/** App-owned file ready for transport, with a safe extension only. */
data class PreparedFile(
    val file: File,
    val fileExtension: String,
    val byteCount: Long,
) {
    val remoteFilename: String
        get() {
            val extension = safeExtension(fileExtension)
            return if (extension.isEmpty()) "file" else "file.$extension"
        }

    companion object {
        const val MAXIMUM_BYTE_COUNT = 64 * 1024 * 1024

        fun safeExtension(candidate: String): String {
            val normalized = candidate.lowercase()
            return normalized.takeIf { value ->
                value.isNotEmpty() && value.length <= 16 && value.all { it in 'a'..'z' || it in '0'..'9' }
            }.orEmpty()
        }
    }
}

/** Upload progress with a clamped display fraction. */
data class AttachmentStageProgress(val transferredBytes: Long, val totalBytes: Long) {
    val fractionCompleted: Double
        get() = if (totalBytes <= 0L) 0.0 else
            (transferredBytes.toDouble() / totalBytes.toDouble()).coerceIn(0.0, 1.0)
}

class StagedImage(path: String) {
    val path: String = checkedStagedHostPath(path)
    override fun equals(other: Any?): Boolean = other is StagedImage && path == other.path
    override fun hashCode(): Int = path.hashCode()
}

class StagedFile(path: String) {
    val path: String = checkedStagedHostPath(path)
    override fun equals(other: Any?): Boolean = other is StagedFile && path == other.path
    override fun hashCode(): Int = path.hashCode()
}

/** Attachment staging failures with retry semantics matching the iOS transport. */
sealed class AttachmentStagingError(message: String) : Exception(message) {
    data object InvalidRemotePath : AttachmentStagingError("Invalid remote path.")
    data object InvalidPreparedSource : AttachmentStagingError("Invalid prepared source.")
    data object LocalReadFailed : AttachmentStagingError("Prepared source could not be read.")
    data object RemoteTemporaryDirectoryFailed : AttachmentStagingError("Remote temporary directory failed.")
    data object SftpUnavailable : AttachmentStagingError("SFTP is unavailable.")
    data object PermissionEnforcementFailed : AttachmentStagingError("Remote permissions could not be enforced.")
    data object ByteCountMismatch : AttachmentStagingError("Uploaded byte count differs.")
    data object TransferFailed : AttachmentStagingError("Attachment transfer failed.")
    data object Cancelled : AttachmentStagingError("Attachment transfer was cancelled.")

    val isRetryable: Boolean
        get() = this === TransferFailed || this === Cancelled
}

private fun String?.nonEmpty(): String? = this?.takeIf(String::isNotEmpty)

private fun checkedStagedHostPath(path: String): String {
    if (!path.startsWith('/') || path == "/" || path.any { it.code < 0x20 || it.code == 0x7f }) {
        throw AttachmentStagingError.InvalidRemotePath
    }
    return path
}

/** Generated wire aliases exposed through the transport boundary. */
typealias SessionSnapshotResult = SessionSnapshot
typealias PaneReadRequest = PaneReadParams
typealias PaneReadResponse = PaneReadResult
typealias AgentReadRequest = AgentReadParams
typealias AgentPromptRequest = AgentPromptParams
typealias AgentRenameRequest = AgentRenameParams
typealias WorkspaceRenameRequest = WorkspaceRenameParams
