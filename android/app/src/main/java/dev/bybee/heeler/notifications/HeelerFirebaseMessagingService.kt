package dev.bybee.heeler.notifications

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ProcessLifecycleOwner
import dev.bybee.heeler.MainActivity
import dev.bybee.heeler.R
import dev.bybee.heeler.core.crypto.NotificationEnvelope
import dev.bybee.heeler.core.crypto.NotificationKeyStore
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Receives encrypted FCM data pushes. Every malformed or undecryptable message
 * gets fixed generic copy; raw data is never put into Android notification UI.
 */
class HeelerFirebaseMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        createChannel()
        if (ProcessLifecycleOwner.get().lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) return
        if (!canPostNotifications()) return

        val rendered = decrypt(message.data[ENVELOPE_KEY])
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(rendered.alert.title)
            .setContentText(rendered.alert.body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(rendered.alert.body))
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setAutoCancel(true)
            .setContentIntent(openIntent(rendered.target))
            .build()
        NotificationManagerCompat.from(this).notify(rendered.tag, NOTIFICATION_ID, notification)
    }

    private fun decrypt(envelope: String?): RenderedNotification {
        if (envelope == null) return RenderedNotification.generic()
        return try {
            val kid = NotificationEnvelope.peekKeyId(envelope) ?: return RenderedNotification.generic()
            val record = NotificationKeyStore.create(applicationContext).recordForKeyId(kid)
                ?: return RenderedNotification.generic()
            val key = record.key
            val payload = try {
                NotificationEnvelope.decrypt(envelope, key)
            } finally {
                key.fill(0)
            }
            RenderedNotification(
                alert = AgentNotificationRenderer.alert(payload),
                target = AgentNotificationTarget(record.hostId.toString(), payload.paneId),
            )
        } catch (_: Exception) {
            RenderedNotification.generic()
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Agent updates",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Blocked and completed Heeler agents"
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun canPostNotifications(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun openIntent(target: AgentNotificationTarget?): PendingIntent {
        val intent = Intent(this, MainActivity::class.java)
            .setAction(PendingNavigationStore.ACTION_OPEN_AGENT)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (target != null) {
            intent.putExtra(PendingNavigationStore.EXTRA_HOST_ID, target.hostId)
            intent.putExtra(PendingNavigationStore.EXTRA_PANE_ID, target.paneId)
        }
        return PendingIntent.getActivity(
            this,
            target?.stableRequestCode() ?: 0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private data class RenderedNotification(
        val alert: AgentNotificationAlert,
        val target: AgentNotificationTarget?,
    ) {
        val tag: String = target?.let { "agent:${it.hostId}:${it.paneId}" } ?: "agent:generic"

        companion object {
            fun generic() = RenderedNotification(AgentNotificationRenderer.fallback, null)
        }
    }

    private companion object {
        const val CHANNEL_ID = "agent_updates"
        const val ENVELOPE_KEY = "envelope"
        const val NOTIFICATION_ID = 1
    }
}

data class AgentNotificationTarget(
    val hostId: String,
    val paneId: String,
) {
    fun route(): String = "agent/${hostId.encodeRouteSegment()}/${paneId.encodeRouteSegment()}"

    fun stableRequestCode(): Int = 31 * hostId.hashCode() + paneId.hashCode()
}

private fun String.encodeRouteSegment(): String = android.net.Uri.encode(this)
