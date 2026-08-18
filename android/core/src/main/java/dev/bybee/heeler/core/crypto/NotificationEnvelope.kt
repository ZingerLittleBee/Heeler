package dev.bybee.heeler.core.crypto

import java.math.BigDecimal
import java.security.GeneralSecurityException
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlinx.serialization.SerializationException
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** A validated Agent-status transition carried in an encrypted notification. */
data class NotificationPayload(
    val paneId: String,
    val agentKind: String,
    val status: String,
    val timestamp: Long,
    val project: String? = null,
    val title: String? = null,
)

/** AES-256-GCM notification envelope v1, shared with the Host plugin. */
object NotificationEnvelope {
    const val VERSION = 1
    private const val KEY_BYTES = 32
    private const val NONCE_BYTES = 12
    private const val TAG_BYTES = 16
    private const val KEY_ID_BYTES = 8
    private const val DISPLAY_FIELD_MAX = 256
    private val aad = "HERDR-NOTIFY:$VERSION".toByteArray(Charsets.UTF_8)
    private val json = Json { ignoreUnknownKeys = true }

    /** Derives the unpadded base64url id used to select a Host's Notification Key. */
    fun keyId(key: ByteArray): String {
        require(key.size == KEY_BYTES) { "Notification Key must be $KEY_BYTES bytes" }
        val digest = MessageDigest.getInstance("SHA-256").digest(key)
        return Base64Url.encode(digest.copyOfRange(0, KEY_ID_BYTES))
    }

    /** Returns a structurally valid key id without attempting decryption. */
    fun peekKeyId(envelope: String): String? {
        val wire = try {
            json.parseToJsonElement(envelope) as? JsonObject
        } catch (_: SerializationException) {
            null
        } ?: return null
        val keyId = wire["kid"].stringOrNull() ?: return null
        return keyId.takeIf { Base64Url.decode(it)?.size == KEY_ID_BYTES }
    }

    /**
     * Encrypts a payload into the compact canonical v1 JSON envelope. [nonce] exists so the
     * cross-platform vectors can assert exact output; production callers leave it null.
     */
    fun encrypt(
        payload: NotificationPayload,
        key: ByteArray,
        nonce: ByteArray? = null,
        random: SecureRandom = SecureRandom(),
    ): String {
        require(key.size == KEY_BYTES) { "Notification Key must be $KEY_BYTES bytes" }
        validatePayload(payload)
        val actualNonce = nonce?.copyOf() ?: ByteArray(NONCE_BYTES).also(random::nextBytes)
        require(actualNonce.size == NONCE_BYTES) { "GCM nonce must be $NONCE_BYTES bytes" }

        val plaintext = encodePayload(payload).toByteArray(Charsets.UTF_8)
        val ciphertext = try {
            Cipher.getInstance("AES/GCM/NoPadding").apply {
                init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BYTES * 8, actualNonce))
                updateAAD(aad)
            }.doFinal(plaintext)
        } catch (error: GeneralSecurityException) {
            throw IllegalStateException("AES-GCM unavailable", error)
        }
        return buildString {
            append("{\"v\":")
            append(VERSION)
            append(",\"kid\":")
            append(json.encodeToString(keyId(key)))
            append(",\"n\":")
            append(json.encodeToString(Base64Url.encode(actualNonce)))
            append(",\"ct\":")
            append(json.encodeToString(Base64Url.encode(ciphertext)))
            append('}')
        }
    }

    /** Decrypts and validates a v1 envelope with the error taxonomy used by the shared vectors. */
    fun decrypt(envelope: String, key: ByteArray): NotificationPayload {
        val element = try {
            json.parseToJsonElement(envelope)
        } catch (_: SerializationException) {
            throw NotificationEnvelopeError.BadEnvelope
        }
        val wire = element as? JsonObject ?: throw NotificationEnvelopeError.BadEnvelope
        val version = wire["v"].integerOrNull() ?: throw NotificationEnvelopeError.BadEnvelope
        if (version != VERSION.toLong()) throw NotificationEnvelopeError.UnsupportedVersion(version)
        wire["kid"].stringOrNull()
            ?.takeIf { Base64Url.decode(it)?.size == KEY_ID_BYTES }
            ?: throw NotificationEnvelopeError.BadEnvelope
        val nonce = wire["n"].stringOrNull()?.let(Base64Url::decode)
            ?.takeIf { it.size == NONCE_BYTES }
            ?: throw NotificationEnvelopeError.BadEnvelope
        val ciphertext = wire["ct"].stringOrNull()?.let(Base64Url::decode)
            ?.takeIf { it.size >= TAG_BYTES }
            ?: throw NotificationEnvelopeError.BadEnvelope
        if (key.size != KEY_BYTES) throw NotificationEnvelopeError.DecryptFailed

        val plaintext = try {
            Cipher.getInstance("AES/GCM/NoPadding").apply {
                init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BYTES * 8, nonce))
                updateAAD(aad)
            }.doFinal(ciphertext)
        } catch (_: GeneralSecurityException) {
            throw NotificationEnvelopeError.DecryptFailed
        }
        return decodePayload(plaintext)
    }

    private fun encodePayload(payload: NotificationPayload): String = buildString {
        append("{\"pane\":")
        append(json.encodeToString(payload.paneId))
        append(",\"kind\":")
        append(json.encodeToString(payload.agentKind))
        append(",\"status\":")
        append(json.encodeToString(payload.status))
        append(",\"ts\":")
        append(payload.timestamp)
        payload.project?.takeIf(String::isNotEmpty)?.let {
            append(",\"project\":")
            append(json.encodeToString(it))
        }
        payload.title?.takeIf(String::isNotEmpty)?.let {
            append(",\"title\":")
            append(json.encodeToString(it))
        }
        append('}')
    }

    private fun decodePayload(plaintext: ByteArray): NotificationPayload {
        val text = Base64Url.decodeUtf8(plaintext) ?: throw NotificationEnvelopeError.BadPayload
        val element = try {
            json.parseToJsonElement(text)
        } catch (_: SerializationException) {
            throw NotificationEnvelopeError.BadPayload
        }
        val wire = element as? JsonObject ?: throw NotificationEnvelopeError.BadPayload
        val paneId = wire["pane"].stringOrNull()?.takeIf(String::isNotEmpty)
            ?: throw NotificationEnvelopeError.BadPayload
        val agentKind = wire["kind"].stringOrNull()?.takeIf(String::isNotEmpty)
            ?: throw NotificationEnvelopeError.BadPayload
        val status = wire["status"].stringOrNull()?.takeIf(String::isNotEmpty)
            ?: throw NotificationEnvelopeError.BadPayload
        val timestamp = wire["ts"].integerOrNull()?.takeIf { it > 0 }
            ?: throw NotificationEnvelopeError.BadPayload
        return NotificationPayload(
            paneId = paneId,
            agentKind = agentKind,
            status = status,
            timestamp = timestamp,
            project = wire.optionalDisplayString("project"),
            title = wire.optionalDisplayString("title"),
        )
    }

    private fun validatePayload(payload: NotificationPayload) {
        if (payload.paneId.isEmpty() || payload.agentKind.isEmpty() || payload.status.isEmpty() || payload.timestamp <= 0) {
            throw NotificationEnvelopeError.BadPayload
        }
        if ((payload.project?.length ?: 0) > DISPLAY_FIELD_MAX || (payload.title?.length ?: 0) > DISPLAY_FIELD_MAX) {
            throw NotificationEnvelopeError.BadPayload
        }
    }

    private fun JsonObject.optionalDisplayString(name: String): String? {
        val value = this[name] ?: return null
        if (value is JsonNull) return null
        val text = value.stringOrNull() ?: throw NotificationEnvelopeError.BadPayload
        if (text.length > DISPLAY_FIELD_MAX) throw NotificationEnvelopeError.BadPayload
        return text.takeIf(String::isNotEmpty)
    }

    private fun JsonElement?.stringOrNull(): String? {
        val primitive = this as? JsonPrimitive ?: return null
        return primitive.content.takeIf { primitive.isString }
    }

    private fun JsonElement?.integerOrNull(): Long? {
        val primitive = this as? JsonPrimitive ?: return null
        if (primitive.isString) return null
        return try {
            BigDecimal(primitive.content).longValueExact()
        } catch (_: NumberFormatException) {
            null
        } catch (_: ArithmeticException) {
            null
        }
    }
}

/** Why an envelope could not produce a notification payload. */
sealed class NotificationEnvelopeError(val wireCode: String) : Exception() {
    data object BadEnvelope : NotificationEnvelopeError("bad_envelope")
    class UnsupportedVersion(val found: Long) : NotificationEnvelopeError("unsupported_version")
    data object DecryptFailed : NotificationEnvelopeError("decrypt_failed")
    data object BadPayload : NotificationEnvelopeError("bad_payload")
}
