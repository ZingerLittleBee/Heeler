package dev.bybee.heeler.console

import dev.bybee.heeler.core.transport.Agent
import dev.bybee.heeler.core.wire.AgentStatus
import java.util.Locale

/** A Host-qualified Pane address. Pane IDs are only unique within one Host. */
data class ConsoleAgentId(
    val hostId: String,
    val paneId: String,
)

/**
 * One flat Console row: an Agent joined to its Host and workspace context.
 * Workspace context decorates a row; it never introduces a second grouping.
 */
data class ConsoleAgent(
    val hostId: String,
    val hostName: String,
    val paneId: String,
    val terminalId: String,
    val kind: String,
    val name: String?,
    val title: String,
    val status: AgentStatus,
    val workspaceId: String,
    val workspaceLabel: String?,
    val repoName: String?,
    val checkoutPath: String?,
    val cwd: String,
    val revision: Int,
    val lastOutputSnippet: String? = null,
    /** Connection identity used to reject work returned by an older session. */
    val connectionGeneration: Long,
) {
    val id: ConsoleAgentId get() = ConsoleAgentId(hostId, paneId)
    val displayName: String get() = name?.takeIf(String::isNotBlank) ?: kind
    val switcherLabel: String get() = workspaceLabel ?: repoName ?: displayName
    val skillsProjectRoot: String? get() = checkoutPath?.takeIf(String::isNotBlank)
        ?: cwd.takeIf(String::isNotBlank)

    companion object {
        fun fromAgent(
            hostId: String,
            hostName: String,
            agent: Agent,
            workspaceLabel: String?,
            repoName: String?,
            checkoutPath: String?,
            lastOutputSnippet: String?,
            connectionGeneration: Long,
        ): ConsoleAgent = ConsoleAgent(
            hostId = hostId,
            hostName = hostName,
            paneId = agent.paneID,
            terminalId = agent.terminalID,
            kind = agent.kind,
            name = agent.name,
            title = agent.title,
            status = agent.status,
            workspaceId = agent.workspaceID,
            workspaceLabel = workspaceLabel,
            repoName = repoName,
            checkoutPath = checkoutPath,
            cwd = agent.cwd,
            revision = agent.revision,
            lastOutputSnippet = lastOutputSnippet,
            connectionGeneration = connectionGeneration,
        )
    }
}

/** Workspace information retained from a Host's latest successful snapshot. */
data class ConsoleWorkspace(
    val id: String,
    val label: String,
)

/** Blocked, Done, Working, Idle, then unknown server values. */
val AgentStatus.consoleSortBucket: Int
    get() = when (rawValue) {
        AgentStatus.blocked.rawValue -> 0
        AgentStatus.done.rawValue -> 1
        AgentStatus.working.rawValue -> 2
        AgentStatus.idle.rawValue -> 3
        else -> 4
    }

/** Stable Console ordering prevents equal-status cards from visually jittering. */
fun List<ConsoleAgent>.consoleSorted(): List<ConsoleAgent> = sortedWith(
    compareBy<ConsoleAgent> { it.status.consoleSortBucket }
        .thenBy { it.hostName.lowercase(Locale.ROOT) }
        .thenBy(ConsoleAgent::hostId)
        .thenBy { it.workspaceLabel.orEmpty() }
        .thenBy(ConsoleAgent::paneId),
)
