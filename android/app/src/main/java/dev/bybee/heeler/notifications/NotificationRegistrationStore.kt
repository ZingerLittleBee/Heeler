package dev.bybee.heeler.notifications

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.bybee.heeler.core.notifications.NotificationRegistrationError
import dev.bybee.heeler.core.transport.Transport
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** The Console's connection owner adapts its `transport(hostId)` method to this boundary. */
fun interface NotificationTransportProvider {
    suspend fun transport(hostId: String): Transport
}

sealed interface PushReadiness {
    data object Loading : PushReadiness
    data object MissingFirebaseConfiguration : PushReadiness
    data class Unavailable(val message: String) : PushReadiness
    data class Ready(val permission: NotificationPermissionState) : PushReadiness
}

data class NotificationHostSettings(
    val registered: Boolean,
    val preferences: NotificationTriggerPreferences,
)

sealed interface NotificationHostState {
    data object Loading : NotificationHostState
    data class Unavailable(val message: String) : NotificationHostState
    data class Idle(val settings: NotificationHostSettings) : NotificationHostState
    data class Updating(val settings: NotificationHostSettings) : NotificationHostState
    data class Failed(val message: String, val settings: NotificationHostSettings) : NotificationHostState
}

/**
 * StateFlow-backed registration state. A displayed host setting always reflects
 * its last confirmed remote registration file; writes never flip it optimistically.
 */
class NotificationRegistrationStore(
    private val appContext: Context,
    private val transports: NotificationTransportProvider,
    private val relaySettings: NotificationRelaySettings = NotificationRelaySettings(appContext),
    private val fcm: FcmTokenClient = FirebaseMessagingClient,
    private val ceremony: NotificationRegistrationCeremony = NotificationRegistrationCeremony.create(appContext),
) : ViewModel() {
    private val _pushReadiness = MutableStateFlow<PushReadiness>(PushReadiness.Loading)
    val pushReadiness: StateFlow<PushReadiness> = _pushReadiness.asStateFlow()

    private val _hostStates = MutableStateFlow<Map<String, NotificationHostState>>(emptyMap())
    val hostStates: StateFlow<Map<String, NotificationHostState>> = _hostStates.asStateFlow()

    private var token: String? = null

    init {
        refreshPushReadiness()
    }

    fun refreshPushReadiness() {
        viewModelScope.launch {
            when (val availability = fcm.availability(appContext)) {
                FirebaseMessagingAvailability.Available -> {
                    _pushReadiness.value = PushReadiness.Loading
                    try {
                        token = fcm.token(appContext)
                        _pushReadiness.value = PushReadiness.Ready(notificationPermissionState(appContext))
                    } catch (error: Exception) {
                        token = null
                        _pushReadiness.value = PushReadiness.Unavailable(
                            error.message ?: "Could not obtain a Firebase registration token.",
                        )
                    }
                }
                FirebaseMessagingAvailability.MissingConfiguration -> {
                    token = null
                    _pushReadiness.value = PushReadiness.MissingFirebaseConfiguration
                }
                is FirebaseMessagingAvailability.Unavailable -> {
                    token = null
                    _pushReadiness.value = PushReadiness.Unavailable(availability.message)
                }
            }
        }
    }

    fun onNotificationPermissionResult(granted: Boolean) {
        val current = _pushReadiness.value
        if (current is PushReadiness.Ready) {
            _pushReadiness.value = PushReadiness.Ready(
                if (granted) NotificationPermissionState.Granted else NotificationPermissionState.Denied,
            )
        }
    }

    fun refreshHost(hostId: String) {
        viewModelScope.launch {
            val fcmToken = token ?: return@launch unavailable(hostId, pushReadinessMessage())
            setState(hostId, NotificationHostState.Loading)
            try {
                val preferences = ceremony.readPreferences(fcmToken, transports.transport(hostId))
                setState(
                    hostId,
                    NotificationHostState.Idle(
                        NotificationHostSettings(
                            registered = preferences != null,
                            preferences = preferences ?: NotificationTriggerPreferences(),
                        ),
                    ),
                )
            } catch (error: Exception) {
                unavailable(hostId, messageFor(error))
            }
        }
    }

    fun setEnabled(hostId: String, hostName: String, enabled: Boolean) {
        viewModelScope.launch {
            val current = confirmedSettings(hostId) ?: return@launch
            if (current.registered == enabled) return@launch
            val fcmToken = tokenOrUnavailable(hostId) ?: return@launch
            if (enabled && notificationPermissionState(appContext) != NotificationPermissionState.Granted) {
                unavailable(hostId, "Allow notifications for Heeler before enabling Host notifications.")
                return@launch
            }
            setState(hostId, NotificationHostState.Updating(current))
            try {
                val transport = transports.transport(hostId)
                val updated = if (enabled) {
                    if (relaySettings.hasInvalidEntry.value) {
                        throw IllegalArgumentException("Enter a valid relay URL before enabling notifications.")
                    }
                    val preferences = NotificationTriggerPreferences()
                    ceremony.register(
                        hostId = hostId,
                        hostName = hostName,
                        fcmToken = fcmToken,
                        preferences = preferences,
                        relayUrl = relaySettings.resolvedRelayUrl(),
                        transport = transport,
                    )
                    NotificationHostSettings(registered = true, preferences = preferences)
                } else {
                    ceremony.unregister(hostId, fcmToken, transport)
                    NotificationHostSettings(registered = false, preferences = NotificationTriggerPreferences())
                }
                setState(hostId, NotificationHostState.Idle(updated))
            } catch (error: Exception) {
                setState(hostId, NotificationHostState.Failed(messageFor(error), current))
            }
        }
    }

    fun setDoneEnabled(hostId: String, hostName: String, enabled: Boolean) {
        viewModelScope.launch {
            val current = confirmedSettings(hostId)
                ?.takeIf { it.registered && it.preferences.done != enabled }
                ?: return@launch
            val fcmToken = tokenOrUnavailable(hostId) ?: return@launch
            if (relaySettings.hasInvalidEntry.value) {
                setState(hostId, NotificationHostState.Failed("Enter a valid relay URL before updating notifications.", current))
                return@launch
            }
            setState(hostId, NotificationHostState.Updating(current))
            val preferences = current.preferences.copy(done = enabled)
            try {
                ceremony.register(
                    hostId = hostId,
                    hostName = hostName,
                    fcmToken = fcmToken,
                    preferences = preferences,
                    relayUrl = relaySettings.resolvedRelayUrl(),
                    transport = transports.transport(hostId),
                )
                setState(hostId, NotificationHostState.Idle(current.copy(preferences = preferences)))
            } catch (error: Exception) {
                setState(hostId, NotificationHostState.Failed(messageFor(error), current))
            }
        }
    }

    /** The fail-closed trigger gate consumed by foreground banners. */
    fun confirmedTriggers(hostId: String): NotificationTriggerPreferences? = confirmedSettings(hostId)
        ?.takeIf(NotificationHostSettings::registered)
        ?.preferences

    private fun tokenOrUnavailable(hostId: String): String? = token ?: run {
        unavailable(hostId, pushReadinessMessage())
        null
    }

    private fun confirmedSettings(hostId: String): NotificationHostSettings? = when (val state = _hostStates.value[hostId]) {
        is NotificationHostState.Idle -> state.settings
        is NotificationHostState.Failed -> state.settings
        else -> null
    }

    private fun setState(hostId: String, state: NotificationHostState) {
        _hostStates.value = _hostStates.value + (hostId to state)
    }

    private fun unavailable(hostId: String, message: String) = setState(hostId, NotificationHostState.Unavailable(message))

    private fun pushReadinessMessage(): String = when (val state = _pushReadiness.value) {
        PushReadiness.Loading -> "Waiting for Firebase registration."
        PushReadiness.MissingFirebaseConfiguration -> "Firebase Messaging is not configured. Add google-services.json to android/app."
        is PushReadiness.Unavailable -> state.message
        is PushReadiness.Ready -> "Allow notifications for Heeler before enabling Host notifications."
    }

    private fun messageFor(error: Throwable): String = when (error) {
        NotificationRegistrationError.PluginNotInstalled -> "Install the Heeler plugin on this Host, then try again."
        is NotificationRegistrationError.PluginProbeFailed -> "Could not check the Heeler plugin on this Host. Check the connection and try again."
        is NotificationRegistrationError.ReadFailed -> "Could not read notification settings from this Host. Check the connection and try again."
        is NotificationRegistrationError.WriteFailed -> "Could not update notification settings on this Host. Check the connection and try again."
        is NotificationRegistrationError.UnsupportedFileVersion,
        is NotificationRegistrationVersionException -> "This Host was registered by a newer app version. Update Heeler."
        else -> "Could not update notification settings. Try again."
    }
}
