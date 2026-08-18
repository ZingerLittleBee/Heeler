package dev.bybee.heeler.core.crypto

import java.io.File
import java.util.Base64
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class PairingCodeVectorTest {
    @Test
    fun everySharedPairingVectorMatchesItsDeclaredContract() {
        val vectors = vectorFile("plugin/test-vectors/pairing-code-v1.json")
        vectors["valid"]!!.jsonArray.forEach { element ->
            val vector = element.jsonObject
            val name = vector.string("name")
            val decoded = PairingCode.decode(vector.string("code"))
            assertPayload(name, vector["payload"]!!.jsonObject, decoded)
            if (vector["decodeOnly"]?.booleanOrFalse() != true) {
                assertEquals(name, vector.string("code"), decoded.encode())
            }
        }
        vectors["invalid"]!!.jsonArray.forEach { element ->
            val vector = element.jsonObject
            val name = vector.string("name")
            try {
                PairingCode.decode(vector.string("code"))
                fail("$name decoded successfully")
            } catch (error: PairingCodeError) {
                assertEquals(name, vector.string("error"), error.wireCode)
            }
        }
    }

    private fun assertPayload(name: String, expected: JsonObject, actual: PairingCode) {
        assertEquals(name, expected["addresses"]!!.jsonArray.map { it.stringValue() }, actual.addresses)
        assertEquals(name, expected.long("port").toInt(), actual.port)
        assertEquals(name, expected.string("username"), actual.username)
        assertEquals(name, expected.string("hostKeyFingerprint"), actual.hostKeyFingerprint.value)
        val expectedSeed = expected["bootstrapSeed"]?.stringValue()
        val expectedExpiry = expected["expiresAt"]?.longValue()
        if (expectedSeed == null && expectedExpiry == null) {
            assertEquals(name, null, actual.bootstrap)
        } else {
            val seed = expectedSeed ?: error("$name omits bootstrapSeed")
            val expiry = expectedExpiry ?: error("$name omits expiresAt")
            val bootstrap = actual.bootstrap ?: error("$name is missing bootstrap material")
            assertArrayEquals(name, Base64.getUrlDecoder().decode(seed), bootstrap.seed)
            assertEquals(name, expiry, bootstrap.expiresAt)
        }
    }

    private fun vectorFile(relativePath: String): JsonObject {
        val root = System.getProperty("heeler.repoRoot") ?: error("heeler.repoRoot must be configured for vector tests")
        return Json.parseToJsonElement(File(root, relativePath).readText()).jsonObject
    }

    private fun JsonObject.string(name: String): String = this[name]!!.stringValue()
    private fun JsonObject.long(name: String): Long = this[name]!!.longValue()
    private fun JsonPrimitive.stringValue(): String = content
    private fun kotlinx.serialization.json.JsonElement.stringValue(): String =
        (this as JsonPrimitive).content
    private fun kotlinx.serialization.json.JsonElement.longValue(): Long =
        (this as JsonPrimitive).content.toLong()
    private fun kotlinx.serialization.json.JsonElement.booleanOrFalse(): Boolean =
        (this as? JsonPrimitive)?.content == "true"
}
