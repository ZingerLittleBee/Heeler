package dev.bybee.heeler.notifications

import dev.bybee.heeler.core.crypto.NotificationPayload

/** The exact safe copy rendered by both FCM notifications and foreground banners. */
data class AgentNotificationAlert(
    val title: String,
    val body: String,
)

object AgentNotificationRenderer {
    val fallback = AgentNotificationAlert(title = "Heeler", body = "Agent update")

    fun alert(payload: NotificationPayload): AgentNotificationAlert = alert(
        project = payload.project,
        agentKind = payload.agentKind,
        task = payload.title,
        status = payload.status,
    )

    fun alert(
        project: String?,
        agentKind: String,
        task: String?,
        status: String,
    ): AgentNotificationAlert {
        val title = listOfNotNull(project.trimmedOrNull(), agentKind.trimmedOrNull())
            .joinToString(separator = " · ")
            .ifBlank { "Agent" }
        val statusWord = when (status.lowercase()) {
            "blocked" -> "Blocked"
            "done" -> "Done"
            else -> status.trimmedOrNull() ?: "Updated"
        }
        val body = task.trimmedOrNull()?.let { "$statusWord · ${it.ellipsized(TASK_LIMIT)}" }
            ?: when (status.lowercase()) {
                "blocked" -> "Blocked: waiting for your input"
                "done" -> "Done: the agent finished"
                else -> "Status: $statusWord"
            }
        return AgentNotificationAlert(title = title, body = body)
    }

    private fun String?.trimmedOrNull(): String? = this?.trim()?.takeIf(String::isNotEmpty)

    private fun String.ellipsized(limit: Int): String {
        if (length <= limit) return this
        return take(limit - 1).trimEnd() + "…"
    }

    private const val TASK_LIMIT = 80
}
