package dev.bybee.heeler.notifications

import android.content.Intent
import dev.bybee.heeler.console.ConsoleAgent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay

/**
 * Holds a notification target until Console's first Host projection confirms
 * that pane. Pending targets expire after 15 seconds and are cancelled by
 * any deliberate user navigation, never stealing focus later.
 */
class PendingNavigationStore(
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
    private val pendingTimeoutMillis: Long = PENDING_TIMEOUT_MILLIS,
) {
    private val routes = Channel<String>(Channel.BUFFERED)
    val navigation: Flow<String> = routes.receiveAsFlow()

    private var knownTargets: Set<AgentNotificationTarget> = emptySet()
    private var pending: AgentNotificationTarget? = null
    private var expiry: Job? = null

    fun acceptIntent(intent: Intent?) {
        if (intent?.action != ACTION_OPEN_AGENT) return
        cancelPending()
        val hostId = intent.getStringExtra(EXTRA_HOST_ID)?.takeIf(String::isNotBlank)
        val paneId = intent.getStringExtra(EXTRA_PANE_ID)?.takeIf(String::isNotBlank)
        val target = if (hostId != null && paneId != null) AgentNotificationTarget(hostId, paneId) else null
        if (target == null) {
            routes.trySend(CONSOLE_ROUTE)
            return
        }
        if (target in knownTargets) {
            routes.trySend(target.route())
        } else {
            pending = target
            expiry = scope.launch {
                delay(pendingTimeoutMillis)
                pending = null
                expiry = null
            }
        }
    }

    /** Called from the Console projection whenever its agent list converges. */
    fun agentsDidChange(targets: Iterable<AgentNotificationTarget>) {
        knownTargets = targets.toSet()
        val target = pending?.takeIf { it in knownTargets } ?: return
        cancelPending()
        routes.trySend(target.route())
    }

    fun agentsDidChange(agents: List<ConsoleAgent>) {
        agentsDidChange(agents.map { agent -> AgentNotificationTarget(agent.hostId, agent.paneId) })
    }

    /** Cancels a cold-launch target before the user's own route action proceeds. */
    fun onUserNavigation() {
        cancelPending()
        while (routes.tryReceive().isSuccess) Unit
    }

    private fun cancelPending() {
        expiry?.cancel()
        expiry = null
        pending = null
    }

    companion object {
        const val ACTION_OPEN_AGENT = "dev.bybee.heeler.notifications.OPEN_AGENT"
        const val EXTRA_HOST_ID = "dev.bybee.heeler.notifications.HOST_ID"
        const val EXTRA_PANE_ID = "dev.bybee.heeler.notifications.PANE_ID"
        const val CONSOLE_ROUTE = "console"
        const val PENDING_TIMEOUT_MILLIS = 15_000L
    }
}
