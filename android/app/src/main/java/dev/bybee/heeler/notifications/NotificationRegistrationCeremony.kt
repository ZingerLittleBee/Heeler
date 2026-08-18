package dev.bybee.heeler.notifications

import android.content.Context
import dev.bybee.heeler.core.crypto.NotificationKeyRecord
import dev.bybee.heeler.core.crypto.NotificationKeyStore
import dev.bybee.heeler.core.transport.Transport
import java.util.UUID
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Per-Host notification enrollment. The local key write always precedes the
 * remote registration replace, so a retry never strands an unreadable Host key.
 */
class NotificationRegistrationCeremony(
    private val keys: NotificationKeyStore,
) {
    suspend fun register(
        hostId: String,
        hostName: String,
        fcmToken: String,
        preferences: NotificationTriggerPreferences = NotificationTriggerPreferences(),
        relayUrl: String = NotificationRelaySettings.DEFAULT_RELAY_URL,
        transport: Transport,
    ): NotificationKeyRecord {
        val id = hostId.asUuid()
        require(fcmToken.isNotBlank()) { "FCM registration token must not be blank." }
        val record = hostRecord(id, hostName)
        keys.save(record)

        val registration = NotificationRegistrationFile.decode(transport.readNotificationRegistration())
        val key = record.key
        try {
            transport.replaceNotificationRegistration(
                registration.upsertingFcm(fcmToken, key, preferences).encoded(),
            )
        } finally {
            key.fill(0)
        }
        writeRelayUrl(relayUrl, transport)
        return record
    }

    suspend fun unregister(
        hostId: String,
        fcmToken: String,
        transport: Transport,
    ) {
        val id = hostId.asUuid()
        require(fcmToken.isNotBlank()) { "FCM registration token must not be blank." }
        val existing = transport.readNotificationRegistration()
        if (existing != null) {
            val registration = NotificationRegistrationFile.decode(existing)
            if (registration.containsDevice(fcmToken)) {
                transport.replaceNotificationRegistration(registration.removing(fcmToken).encoded())
            }
        }
        keys.removeRecord(id)
    }

    suspend fun readPreferences(fcmToken: String, transport: Transport): NotificationTriggerPreferences? =
        NotificationRegistrationFile.decode(transport.readNotificationRegistration()).preferences(fcmToken)

    private fun hostRecord(hostId: UUID, hostName: String): NotificationKeyRecord {
        val old = keys.recordForHost(hostId)
        val key = old?.key ?: NotificationKeyStore.generateKey()
        return try {
            NotificationKeyRecord(hostId, hostName.ifBlank { "Host" }, key)
        } finally {
            key.fill(0)
        }
    }

    private suspend fun writeRelayUrl(relayUrl: String, transport: Transport) {
        val normalized = NotificationRelaySettings.validRelayUrlOrNull(relayUrl)
            ?: throw IllegalArgumentException("Relay URL must be an absolute http(s) URL without a query or fragment.")
        val config = NotificationConfigFile.decode(transport.readNotificationConfig())
        val updated = config.settingRelayUrl(normalized)
        if (updated != config) transport.replaceNotificationConfig(updated.encoded())
    }

    companion object {
        fun create(context: Context): NotificationRegistrationCeremony =
            NotificationRegistrationCeremony(NotificationKeyStore.create(context.applicationContext))
    }
}

private fun String.asUuid(): UUID = try {
    UUID.fromString(this)
} catch (_: IllegalArgumentException) {
    throw IllegalArgumentException("Host id must be a UUID.")
}

/** The Host's schema-free notify.json; only relay_url is owned by the app. */
private class NotificationConfigFile private constructor(
    private val fields: Map<String, kotlinx.serialization.json.JsonElement>,
) {
    fun settingRelayUrl(url: String): NotificationConfigFile = NotificationConfigFile(
        fields + (RELAY_URL_KEY to JsonPrimitive(url.trimEnd('/'))),
    )

    fun encoded(): ByteArray = json.encodeToString(JsonObject.serializer(), JsonObject(fields)).encodeToByteArray()

    override fun equals(other: Any?): Boolean = other is NotificationConfigFile && fields == other.fields
    override fun hashCode(): Int = fields.hashCode()

    companion object {
        private const val RELAY_URL_KEY = "relay_url"
        private val json = Json { ignoreUnknownKeys = true }

        fun decode(bytes: ByteArray?): NotificationConfigFile {
            if (bytes == null) return NotificationConfigFile(emptyMap())
            val decoded = try {
                json.parseToJsonElement(bytes.decodeToString()) as? JsonObject
            } catch (_: SerializationException) {
                null
            } catch (_: IllegalArgumentException) {
                null
            }
            return NotificationConfigFile(decoded ?: emptyMap())
        }
    }
}
