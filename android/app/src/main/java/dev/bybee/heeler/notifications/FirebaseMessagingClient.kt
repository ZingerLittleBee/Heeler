package dev.bybee.heeler.notifications

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import com.google.android.gms.tasks.Task
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine

/** The Firebase prerequisite is explicit because google-services.json is optional for this project. */
sealed interface FirebaseMessagingAvailability {
    data object Available : FirebaseMessagingAvailability
    data object MissingConfiguration : FirebaseMessagingAvailability
    data class Unavailable(val message: String) : FirebaseMessagingAvailability
}

/** Android's POST_NOTIFICATIONS state, which must gate local notification presentation. */
sealed interface NotificationPermissionState {
    data object Granted : NotificationPermissionState
    data object NeedsRequest : NotificationPermissionState
    data object Denied : NotificationPermissionState
}

interface FcmTokenClient {
    fun availability(context: Context): FirebaseMessagingAvailability
    suspend fun token(context: Context): String
}

object FirebaseMessagingClient : FcmTokenClient {
    override fun availability(context: Context): FirebaseMessagingAvailability = try {
        if (FirebaseApp.initializeApp(context.applicationContext) == null) {
            FirebaseMessagingAvailability.MissingConfiguration
        } else {
            FirebaseMessagingAvailability.Available
        }
    } catch (_: IllegalStateException) {
        FirebaseMessagingAvailability.MissingConfiguration
    } catch (error: RuntimeException) {
        FirebaseMessagingAvailability.Unavailable(error.message ?: "Firebase could not initialize.")
    }

    override suspend fun token(context: Context): String {
        check(availability(context) is FirebaseMessagingAvailability.Available) {
            "Firebase Messaging is not configured. Add google-services.json to android/app."
        }
        return FirebaseMessaging.getInstance().token.awaitValue().also { token ->
            require(token.isNotBlank()) { "Firebase returned an empty registration token." }
        }
    }
}

fun notificationPermissionState(context: Context): NotificationPermissionState {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return NotificationPermissionState.Granted
    return when (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS)) {
        PackageManager.PERMISSION_GRANTED -> NotificationPermissionState.Granted
        else -> NotificationPermissionState.NeedsRequest
    }
}

internal suspend fun <T> Task<T>.awaitValue(): T = suspendCancellableCoroutine { continuation ->
    addOnSuccessListener { value ->
        if (continuation.isActive) continuation.resume(value)
    }
    addOnFailureListener { error ->
        if (continuation.isActive) continuation.resumeWithException(error)
    }
    addOnCanceledListener {
        continuation.cancel()
    }
}
