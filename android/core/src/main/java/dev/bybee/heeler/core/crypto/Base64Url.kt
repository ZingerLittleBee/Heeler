package dev.bybee.heeler.core.crypto

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.util.Base64

/** Strict RFC 4648 base64url without padding, used by the versioned wire formats. */
internal object Base64Url {
    private val alphabet = Regex("[A-Za-z0-9_-]+")

    fun encode(bytes: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

    /** Returns null for padding, a non-url alphabet character, or invalid encoded length. */
    fun decode(text: String): ByteArray? {
        if (!alphabet.matches(text) || text.length % 4 == 1) return null
        return try {
            Base64.getUrlDecoder().decode(text)
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    /** UTF-8 decoding that never quietly replaces malformed bytes. */
    fun decodeUtf8(bytes: ByteArray): String? = try {
        StandardCharsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes))
            .toString()
    } catch (_: CharacterCodingException) {
        null
    }
}
