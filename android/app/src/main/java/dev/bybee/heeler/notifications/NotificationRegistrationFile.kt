package dev.bybee.heeler.notifications

import java.util.Base64
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull

/** The notification triggers a device has explicitly enabled on a Host. */
data class NotificationTriggerPreferences(
    val blocked: Boolean = true,
    val done: Boolean = true,
)

/**
 * The v1 registration file owned by the Host notification plugin. Its object
 * fields and foreign device entries stay as parsed JSON so an Android rewrite
 * never loses another app version's additive metadata.
 */
class NotificationRegistrationFile private constructor(
    private val fields: Map<String, JsonElement>,
) {
    fun containsDevice(token: String): Boolean = devices.any { it.token() == token }

    fun preferences(token: String): NotificationTriggerPreferences? = devices
        .firstOrNull { it.token() == token }
        ?.let { device ->
            val notify = (device as? JsonObject)?.get("notify") as? JsonObject
            NotificationTriggerPreferences(
                blocked = notify?.get("blocked").booleanOrFalse(),
                done = notify?.get("done").booleanOrFalse(),
            )
        }

    fun upsertingFcm(
        token: String,
        key: ByteArray,
        preferences: NotificationTriggerPreferences,
    ): NotificationRegistrationFile {
        require(token.isNotBlank()) { "FCM registration token must not be blank." }
        require(key.size == KEY_BYTES) { "Notification Key must be $KEY_BYTES bytes." }
        val updatedDevices = devices.toMutableList()
        val existing = updatedDevices.indexOfFirst { it.token() == token }
        val entry = JsonObject(
            linkedMapOf(
                "provider" to JsonPrimitive("fcm"),
                "token" to JsonPrimitive(token),
                "key" to JsonPrimitive(Base64.getUrlEncoder().withoutPadding().encodeToString(key)),
                "notify" to JsonObject(
                    linkedMapOf(
                        "blocked" to JsonPrimitive(preferences.blocked),
                        "done" to JsonPrimitive(preferences.done),
                    ),
                ),
            ),
        )
        if (existing >= 0) {
            updatedDevices[existing] = entry
        } else {
            updatedDevices += entry
        }
        return NotificationRegistrationFile(fields + (DEVICES_KEY to JsonArray(updatedDevices)))
    }

    fun removing(token: String): NotificationRegistrationFile = NotificationRegistrationFile(
        fields + (DEVICES_KEY to JsonArray(devices.filterNot { it.token() == token })),
    )

    fun encoded(): ByteArray = json.encodeToString(JsonObject.serializer(), encodedObject()).encodeToByteArray()

    private val devices: List<JsonElement>
        get() = (fields[DEVICES_KEY] as? JsonArray).orEmpty()

    private fun encodedObject(): JsonObject = JsonObject(
        linkedMapOf<String, JsonElement>().apply {
            putAll(fields)
            put(VERSION_KEY, JsonPrimitive(VERSION))
            put(DEVICES_KEY, JsonArray(devices))
        },
    )

    companion object {
        const val VERSION = 1
        private const val VERSION_KEY = "v"
        private const val DEVICES_KEY = "devices"
        private const val KEY_BYTES = 32
        private val json = Json { ignoreUnknownKeys = true }

        /**
         * Absence and malformed content mean no registered devices, mirroring
         * the plugin's fail-closed reader. A parseable different version is
         * deliberately refused rather than overwritten.
         */
        fun decode(bytes: ByteArray?): NotificationRegistrationFile {
            if (bytes == null) return NotificationRegistrationFile(emptyMap())
            val objectValue = try {
                json.parseToJsonElement(bytes.decodeToString()) as? JsonObject
            } catch (_: SerializationException) {
                null
            } catch (_: IllegalArgumentException) {
                null
            } ?: return NotificationRegistrationFile(emptyMap())

            val version = objectValue[VERSION_KEY].integerOrNull() ?: return NotificationRegistrationFile(emptyMap())
            if (version != VERSION) throw NotificationRegistrationVersionException(version)
            if (objectValue[DEVICES_KEY] !is JsonArray && objectValue[DEVICES_KEY] != null) {
                return NotificationRegistrationFile(emptyMap())
            }
            return NotificationRegistrationFile(objectValue)
        }
    }
}

class NotificationRegistrationVersionException(val version: Int) : Exception(
    "Unsupported notification registration version $version.",
)

private fun JsonElement.token(): String? = (this as? JsonObject)
    ?.get("token")
    ?.let { it as? JsonPrimitive }
    ?.takeIf(JsonPrimitive::isString)
    ?.content

private fun JsonElement?.booleanOrFalse(): Boolean = (this as? JsonPrimitive)
    ?.takeIf { !it.isString }
    ?.booleanOrNull ?: false

private fun JsonElement?.integerOrNull(): Int? = (this as? JsonPrimitive)
    ?.takeIf { !it.isString }
    ?.intOrNull
