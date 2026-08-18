package dev.bybee.heeler.core.crypto

import java.io.File
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class NotificationEnvelopeVectorTest {
    @Test
    fun everySharedNotificationVectorMatchesItsDeclaredContract() {
        val vectors = vectorFile("plugin/test-vectors/notification-payload-v1.json")
        vectors["valid"]!!.jsonArray.forEach { element ->
            val vector = element.jsonObject
            val name = vector.string("name")
            val key = Base64.getUrlDecoder().decode(vector.string("key"))
            assertEquals(name, vector.string("keyId"), NotificationEnvelope.keyId(key))
            val payload = NotificationEnvelope.decrypt(vector.string("envelope"), key)
            assertPayload(name, vector["payload"]!!.jsonObject, payload)
            if (vector["decodeOnly"]?.booleanOrFalse() != true) {
                val nonce = envelopeNonce(vector.string("envelope"))
                assertEquals(name, vector.string("envelope"), NotificationEnvelope.encrypt(payload, key, nonce))
            }
        }
        vectors["invalid"]!!.jsonArray.forEach { element ->
            val vector = element.jsonObject
            val name = vector.string("name")
            val key = Base64.getUrlDecoder().decode(vector.string("key"))
            try {
                NotificationEnvelope.decrypt(vector.string("envelope"), key)
                fail("$name decrypted successfully")
            } catch (error: NotificationEnvelopeError) {
                assertEquals(name, vector.string("error"), error.wireCode)
            }
        }
    }

    @Test
    fun encryptionRejectsDisplayFieldsAboveTheWireCeiling() {
        val key = ByteArray(32)
        try {
            NotificationEnvelope.encrypt(
                NotificationPayload("%5", "claude", "blocked", 1, title = "a".repeat(257)),
                key,
                ByteArray(12),
            )
            fail("oversized title encrypted successfully")
        } catch (error: NotificationEnvelopeError) {
            assertEquals("bad_payload", error.wireCode)
        }
    }

    @Test
    fun decryptionRejectsDisplayFieldsAboveTheWireCeiling() {
        val key = ByteArray(32)
        val title = "a".repeat(257)
        val plaintext = """{"pane":"%5","kind":"claude","status":"blocked","ts":1,"title":"$title"}"""
        try {
            NotificationEnvelope.decrypt(rawEnvelope(plaintext, key), key)
            fail("oversized decrypted title was accepted")
        } catch (error: NotificationEnvelopeError) {
            assertEquals("bad_payload", error.wireCode)
        }
    }

    private fun assertPayload(name: String, expected: JsonObject, actual: NotificationPayload) {
        assertEquals(name, expected.string("paneId"), actual.paneId)
        assertEquals(name, expected.string("agentKind"), actual.agentKind)
        assertEquals(name, expected.string("status"), actual.status)
        assertEquals(name, expected.long("timestamp"), actual.timestamp)
        assertEquals(name, expected["project"]?.stringOrNull(), actual.project)
        assertEquals(name, expected["title"]?.stringOrNull(), actual.title)
    }

    private fun envelopeNonce(envelope: String): ByteArray {
        val wire = Json.parseToJsonElement(envelope).jsonObject
        return Base64.getUrlDecoder().decode(wire.string("n"))
    }

    private fun rawEnvelope(plaintext: String, key: ByteArray): String {
        val nonce = ByteArray(12)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
            updateAAD("HERDR-NOTIFY:1".toByteArray(Charsets.UTF_8))
        }
        val encoded = Base64.getUrlEncoder().withoutPadding()
        val ciphertext = cipher.doFinal(plaintext.toByteArray(Charsets.UTF_8))
        return """{"v":1,"kid":"${NotificationEnvelope.keyId(key)}","n":"${encoded.encodeToString(nonce)}","ct":"${encoded.encodeToString(ciphertext)}"}"""
    }

    private fun vectorFile(relativePath: String): JsonObject {
        val root = System.getProperty("heeler.repoRoot") ?: error("heeler.repoRoot must be configured for vector tests")
        return Json.parseToJsonElement(File(root, relativePath).readText()).jsonObject
    }

    private fun JsonObject.string(name: String): String = this[name]!!.stringOrNull()!!
    private fun JsonObject.long(name: String): Long = this[name]!!.longValue()
    private fun JsonElement.stringOrNull(): String? =
        (this as? JsonPrimitive)?.takeIf { it.isString }?.content
    private fun JsonElement.longValue(): Long = (this as JsonPrimitive).content.toLong()
    private fun JsonElement.booleanOrFalse(): Boolean =
        (this as? JsonPrimitive)?.content == "true"
}
