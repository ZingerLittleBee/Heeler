package dev.bybee.heeler.core.crypto

import java.math.BigDecimal
import kotlinx.serialization.SerializationException
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** A validated v1 Pairing Code payload. */
data class PairingCode(
    val addresses: List<String>,
    val port: Int,
    val username: String,
    val hostKeyFingerprint: HostKeyFingerprint,
    val bootstrap: Bootstrap? = null,
) {
    /** The single-use Bootstrap Key material carried only in a pairing scan. */
    class Bootstrap(seed: ByteArray, val expiresAt: Long) {
        val seed: ByteArray = seed.copyOf()

        override fun equals(other: Any?): Boolean =
            other is Bootstrap && expiresAt == other.expiresAt && seed.contentEquals(other.seed)

        override fun hashCode(): Int = 31 * seed.contentHashCode() + expiresAt.hashCode()
    }

    /** Emits the compact, fixed-key-order v1 representation. */
    fun encode(): String {
        validate(
            addresses = addresses,
            port = port.toLong(),
            username = username,
            fingerprint = hostKeyFingerprint,
            bootstrap = bootstrap,
        )
        val body = buildString {
            append("{\"addrs\":")
            append(json.encodeToString(addresses))
            append(",\"port\":")
            append(port)
            append(",\"user\":")
            append(json.encodeToString(username))
            append(",\"fp\":")
            append(json.encodeToString(hostKeyFingerprint.value))
            bootstrap?.let {
                append(",\"seed\":")
                append(json.encodeToString(Base64Url.encode(it.seed)))
                append(",\"exp\":")
                append(it.expiresAt)
            }
            append('}')
        }
        return "$PREFIX:$VERSION:${Base64Url.encode(body.toByteArray(Charsets.UTF_8))}"
    }

    companion object {
        const val PREFIX = "HERDR-PAIR"
        const val VERSION = 1
        private const val BOOTSTRAP_SEED_BYTES = 32
        private val json = Json { ignoreUnknownKeys = true }

        /** Parses a scanned v1 Pairing Code with the shared wire-error taxonomy. */
        fun decode(scanned: String): PairingCode {
            if (!scanned.startsWith("$PREFIX:")) throw PairingCodeError.BadPrefix
            val rest = scanned.substring(PREFIX.length + 1)
            val separator = rest.indexOf(':')
            if (separator < 0) throw PairingCodeError.BadPrefix
            val foundVersion = rest.substring(0, separator)
            if (foundVersion != VERSION.toString()) {
                throw PairingCodeError.UnsupportedVersion(foundVersion)
            }

            val body = Base64Url.decode(rest.substring(separator + 1))
                ?: throw PairingCodeError.BadEncoding
            val bodyText = Base64Url.decodeUtf8(body) ?: throw PairingCodeError.BadEncoding
            val element = try {
                json.parseToJsonElement(bodyText)
            } catch (_: SerializationException) {
                throw PairingCodeError.BadEncoding
            }
            val wire = element as? JsonObject ?: throw PairingCodeError.BadPayload

            val addresses = wire["addrs"].stringArrayOrNull()
                ?: throw PairingCodeError.BadPayload
            val port = wire["port"].integerOrNull()
                ?: throw PairingCodeError.BadPayload
            val username = wire["user"].stringOrNull()
                ?: throw PairingCodeError.BadPayload
            val fingerprint = wire["fp"].stringOrNull()?.let(HostKeyFingerprint::parse)
                ?: throw PairingCodeError.BadPayload

            val hasSeed = "seed" in wire
            val hasExpiry = "exp" in wire
            val bootstrap = when {
                !hasSeed && !hasExpiry -> null
                hasSeed && hasExpiry -> {
                    val seed = wire["seed"].stringOrNull()?.let(Base64Url::decode)
                        ?: throw PairingCodeError.BadPayload
                    val expiresAt = wire["exp"].integerOrNull()
                        ?: throw PairingCodeError.BadPayload
                    try {
                        Bootstrap(seed, expiresAt)
                    } finally {
                        seed.fill(0)
                    }
                }
                else -> throw PairingCodeError.BadPayload
            }

            validate(addresses, port, username, fingerprint, bootstrap)
            return PairingCode(addresses.toList(), port.toInt(), username, fingerprint, bootstrap)
        }

        private fun validate(
            addresses: List<String>,
            port: Long,
            username: String,
            fingerprint: HostKeyFingerprint,
            bootstrap: Bootstrap?,
        ) {
            if (addresses.isEmpty() || addresses.any { it.isEmpty() || it.containsWhitespace() }) {
                throw PairingCodeError.BadPayload
            }
            if (port !in 1L..65535L) throw PairingCodeError.BadPayload
            if (username.isEmpty() || username.containsWhitespace()) throw PairingCodeError.BadPayload
            // A HostKeyFingerprint instance can only originate from an exact wire-format parse.
            if (HostKeyFingerprint.parse(fingerprint.value) == null) throw PairingCodeError.BadPayload
            if (bootstrap != null && (bootstrap.seed.size != BOOTSTRAP_SEED_BYTES || bootstrap.expiresAt <= 0)) {
                throw PairingCodeError.BadPayload
            }
        }

        private fun JsonElement?.stringArrayOrNull(): List<String>? {
            val array = this as? JsonArray ?: return null
            return array.map { it.stringOrNull() ?: return null }
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

        private fun String.containsWhitespace(): Boolean =
            any { it.isWhitespace() || Character.isSpaceChar(it) }
    }
}

/** Why an input did not produce a Pairing Code. [wireCode] matches the shared vectors. */
sealed class PairingCodeError(val wireCode: String) : Exception() {
    data object BadPrefix : PairingCodeError("bad_prefix")
    class UnsupportedVersion(val found: String) : PairingCodeError("unsupported_version")
    data object BadEncoding : PairingCodeError("bad_encoding")
    data object BadPayload : PairingCodeError("bad_payload")
}
