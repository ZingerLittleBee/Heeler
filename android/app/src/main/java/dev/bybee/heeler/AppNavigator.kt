package dev.bybee.heeler

import android.net.Uri
import dev.bybee.heeler.notifications.AgentNotificationTarget
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow

/**
 * App-owned route bridge for actions initiated below NavHost (for example the
 * Agent detail switcher). NavHost remains the only NavController owner.
 */
class AppNavigator {
    private val routeChannel = Channel<String>(Channel.BUFFERED)
    val routes: Flow<String> = routeChannel.receiveAsFlow()

    private val mutablePresentedAgent = MutableStateFlow<AgentNotificationTarget?>(null)
    val presentedAgent: StateFlow<AgentNotificationTarget?> = mutablePresentedAgent.asStateFlow()

    fun openAgent(hostId: String, paneId: String) {
        routeChannel.trySend(agentRoute(hostId, paneId))
    }

    fun open(route: String) {
        routeChannel.trySend(route)
    }

    /** Called by NavHost after every destination change. */
    fun destinationChanged(route: String?) {
        mutablePresentedAgent.value = route?.agentTargetOrNull()
    }
    companion object {
        fun agentRoute(hostId: String, paneId: String): String =
            "agent/${Uri.encode(hostId)}/${Uri.encode(paneId)}"
    }
}


private fun String.agentTargetOrNull(): AgentNotificationTarget? {
    val segments = split('/')
    return if (segments.size == 3 && segments[0] == "agent") {
        AgentNotificationTarget(Uri.decode(segments[1]), Uri.decode(segments[2]))
    } else {
        null
    }
}
