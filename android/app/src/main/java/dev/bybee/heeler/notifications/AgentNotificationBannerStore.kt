package dev.bybee.heeler.notifications
import dev.bybee.heeler.console.ConsoleAgent

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** Minimal Console projection consumed by foreground notification banners. */
data class ForegroundAgent(
    val hostId: String,
    val paneId: String,
    val status: String,
    val agentKind: String,
    val project: String? = null,
    val title: String? = null,
) {
    val target: AgentNotificationTarget get() = AgentNotificationTarget(hostId, paneId)
}

data class AgentNotificationBanner(
    val target: AgentNotificationTarget,
    val alert: AgentNotificationAlert,
)

/**
 * Derives debounced Blocked/Done announcements from Console's converged agent
 * projection. Initial snapshots establish a baseline and never banner.
 */
class AgentNotificationBannerStore(
    private val presentedAgent: () -> AgentNotificationTarget?,
    private val triggers: (hostId: String) -> NotificationTriggerPreferences?,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
    private val holdMillis: Long = HOLD_MILLIS,
    private val dismissMillis: Long = DISMISS_MILLIS,
) {
    private val _banner = MutableStateFlow<AgentNotificationBanner?>(null)
    val banner: StateFlow<AgentNotificationBanner?> = _banner.asStateFlow()

    private val statuses = mutableMapOf<AgentNotificationTarget, String>()
    private val holds = mutableMapOf<AgentNotificationTarget, Job>()
    private var dismissal: Job? = null

    fun agentsDidChange(agents: Iterable<ForegroundAgent>) {
        val current = agents.associateBy(ForegroundAgent::target)
        statuses.keys.toList().filterNot(current::containsKey).forEach { target ->
            statuses.remove(target)
            cancelHold(target)
        }
        current.forEach { (target, agent) ->
            val previous = statuses.put(target, agent.status)
            if (previous == agent.status) return@forEach
            cancelHold(target)
            if (previous == null || !agent.status.isNotifiableStatus()) return@forEach
            holds[target] = scope.launch {
                delay(holdMillis)
                holds.remove(target)
                if (statuses[target] == agent.status) present(agent)
            }
        }
    }

    fun agentsDidChange(agents: List<ConsoleAgent>) {
        agentsDidChange(
            agents.map { agent ->
                ForegroundAgent(
                    hostId = agent.hostId,
                    paneId = agent.paneId,
                    status = agent.status.rawValue,
                    agentKind = agent.kind,
                    project = agent.workspaceLabel ?: agent.repoName,
                    title = agent.title,
                )
            },
        )
    }

    fun dismiss() {
        dismissal?.cancel()
        dismissal = null
        _banner.value = null
    }

    private fun present(agent: ForegroundAgent) {
        val target = agent.target
        if (target == presentedAgent()) return
        val notify = triggers(agent.hostId) ?: return
        if (agent.status.equals("blocked", ignoreCase = true) && !notify.blocked) return
        if (agent.status.equals("done", ignoreCase = true) && !notify.done) return

        _banner.value = AgentNotificationBanner(
            target = target,
            alert = AgentNotificationRenderer.alert(
                project = agent.project,
                agentKind = agent.agentKind,
                task = agent.title,
                status = agent.status,
            ),
        )
        dismissal?.cancel()
        dismissal = scope.launch {
            delay(dismissMillis)
            _banner.value = null
            dismissal = null
        }
    }

    private fun cancelHold(target: AgentNotificationTarget) {
        holds.remove(target)?.cancel()
    }

    private fun String.isNotifiableStatus(): Boolean =
        equals("blocked", ignoreCase = true) || equals("done", ignoreCase = true)

    companion object {
        const val HOLD_MILLIS = 3_000L
        const val DISMISS_MILLIS = 5_000L
    }
}
