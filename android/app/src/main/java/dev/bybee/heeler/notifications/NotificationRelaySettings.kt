package dev.bybee.heeler.notifications

import android.content.Context
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import java.net.URI
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn

private val Context.notificationRelayDataStore by preferencesDataStore(name = "notification_relay")

/**
 * The app-side relay preference. An empty value means the official relay;
 * registration resolves it before writing the Host's `notify.json`.
 */
class NotificationRelaySettings(context: Context) {
    private val applicationContext = context.applicationContext
    private val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.IO)

    val rawValue: StateFlow<String> = preferences()
        .map { it[RELAY_URL_KEY].orEmpty() }
        .stateIn(scope, SharingStarted.Eagerly, "")

    val relayUrl: StateFlow<String?> = rawValue
        .map(::validRelayUrlOrNull)
        .stateIn(scope, SharingStarted.Eagerly, null)

    val hasInvalidEntry: StateFlow<Boolean> = rawValue
        .map { value -> value.isNotBlank() && validRelayUrlOrNull(value) == null }
        .stateIn(scope, SharingStarted.Eagerly, false)

    /** Stores user input verbatim except for surrounding whitespace. */
    suspend fun setRawValue(value: String) {
        val normalized = value.trim()
        applicationContext.notificationRelayDataStore.edit { preferences ->
            if (normalized.isEmpty()) preferences.remove(RELAY_URL_KEY) else preferences[RELAY_URL_KEY] = normalized
        }
    }

    /** The valid configured relay or the production default for a Host write. */
    fun resolvedRelayUrl(): String = relayUrl.value ?: DEFAULT_RELAY_URL

    private fun preferences(): Flow<Preferences> = applicationContext.notificationRelayDataStore.data
        .catch { error ->
            if (error is java.io.IOException) emit(emptyPreferences()) else throw error
        }

    companion object {
        const val DEFAULT_RELAY_URL = "https://heeler-apns.bybee.dev"
        private val RELAY_URL_KEY = stringPreferencesKey("relay_url")

        /** Returns a normalized absolute http(s) relay base URL, or null when invalid or unset. */
        fun validRelayUrlOrNull(value: String): String? {
            val trimmed = value.trim()
            if (trimmed.isEmpty()) return null
            val uri = try {
                URI(trimmed)
            } catch (_: IllegalArgumentException) {
                return null
            }
            if (uri.scheme?.lowercase() !in setOf("http", "https") || uri.host.isNullOrBlank()) return null
            if (uri.query != null || uri.fragment != null) return null
            return trimmed.trimEnd('/')
        }
    }
}
