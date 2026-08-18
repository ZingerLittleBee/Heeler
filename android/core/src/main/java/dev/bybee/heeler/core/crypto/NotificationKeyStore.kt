package dev.bybee.heeler.core.crypto

import android.content.Context
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.security.SecureRandom
import java.util.UUID

/** A per-Host raw 32-byte Notification Key and the display information needed by FCM rendering. */
class NotificationKeyRecord(
    val hostId: UUID,
    val hostName: String,
    key: ByteArray,
) {
    private val keyMaterial = key.copyOf()

    /** Returns a copy so callers cannot mutate the stored record's key material. */
    val key: ByteArray get() = keyMaterial.copyOf()
    internal val keySize: Int get() = keyMaterial.size

    /** Derived on demand; it is never persisted alongside the secret key. */
    val keyId: String get() = NotificationEnvelope.keyId(keyMaterial)

    override fun equals(other: Any?): Boolean =
        other is NotificationKeyRecord &&
            hostId == other.hostId &&
            hostName == other.hostName &&
            keyMaterial.contentEquals(other.keyMaterial)

    override fun hashCode(): Int = 31 * (31 * hostId.hashCode() + hostName.hashCode()) + keyMaterial.contentHashCode()
}

/**
 * Keystore-wrapped Notification Keys, one record per Host. FCM handling can use [recordForKeyId]
 * before app launch because the record index and every record are independently encrypted at rest.
 */
class NotificationKeyStore(private val storage: EncryptedRecordStore) {
    fun save(record: NotificationKeyRecord) {
        validate(record)
        val encoded = encode(record)
        try {
            storage.write(account(record.hostId), encoded)
        } catch (error: EncryptedRecordStoreException) {
            throw NotificationKeyStoreError.StorageFailure(error)
        } finally {
            encoded.fill(0)
        }
    }

    fun recordForHost(hostId: UUID): NotificationKeyRecord? = readRecord(hostId)

    fun recordForKeyId(keyId: String): NotificationKeyRecord? =
        allRecords().firstOrNull { it.keyId == keyId }

    /** Skips only corrupt individual records; other Hosts remain eligible for notification delivery. */
    fun allRecords(): List<NotificationKeyRecord> {
        val accounts = try {
            storage.accounts()
        } catch (error: EncryptedRecordStoreException) {
            throw NotificationKeyStoreError.StorageFailure(error)
        }
        return accounts.mapNotNull { account ->
            if (!account.startsWith(ACCOUNT_PREFIX)) return@mapNotNull null
            val hostId = uuidFromStringOrNull(account.removePrefix(ACCOUNT_PREFIX))
                ?: return@mapNotNull null
            readRecord(hostId)
        }
    }

    fun removeRecord(hostId: UUID) {
        try {
            storage.remove(account(hostId))
        } catch (error: EncryptedRecordStoreException) {
            throw NotificationKeyStoreError.StorageFailure(error)
        }
    }

    private fun readRecord(hostId: UUID): NotificationKeyRecord? {
        val raw = try {
            storage.read(account(hostId))
        } catch (_: EncryptedRecordStoreException.Corrupt) {
            return null
        } catch (error: EncryptedRecordStoreException) {
            throw NotificationKeyStoreError.StorageFailure(error)
        } ?: return null
        try {
            return decode(hostId, raw)
        } finally {
            raw.fill(0)
        }
    }

    private fun validate(record: NotificationKeyRecord) {
        if (
            record.keySize != KEY_BYTES ||
            record.hostName.isBlank() ||
            record.hostName.toByteArray(Charsets.UTF_8).size > MAX_NAME_BYTES
        ) {
            throw NotificationKeyStoreError.InvalidRecord
        }
    }

    private fun encode(record: NotificationKeyRecord): ByteArray {
        val key = record.key
        try {
            return ByteArrayOutputStream().use { bytes ->
                DataOutputStream(bytes).use { output ->
                    val name = record.hostName.toByteArray(Charsets.UTF_8)
                    output.writeInt(RECORD_VERSION)
                    output.writeInt(name.size)
                    output.write(name)
                    output.write(key)
                }
                bytes.toByteArray()
            }
        } finally {
            key.fill(0)
        }
    }

    private fun decode(hostId: UUID, raw: ByteArray): NotificationKeyRecord? {
        return try {
            DataInputStream(ByteArrayInputStream(raw)).use { input ->
                if (input.readInt() != RECORD_VERSION) return null
                val nameLength = input.readInt()
                if (nameLength !in 1..MAX_NAME_BYTES) return null
                val name = ByteArray(nameLength)
                input.readFully(name)
                val key = ByteArray(KEY_BYTES)
                input.readFully(key)
                try {
                    if (input.available() != 0) return null
                    val hostName = Base64Url.decodeUtf8(name) ?: return null
                    if (hostName.isBlank()) return null
                    NotificationKeyRecord(hostId, hostName, key)
                } finally {
                    key.fill(0)
                }
            }
        } catch (_: IOException) {
            null
        }
    }

    companion object {
        private const val ACCOUNT_PREFIX = "notification-key:"
        private const val RECORD_VERSION = 1
        private const val KEY_BYTES = 32
        private const val MAX_NAME_BYTES = 65_535

        /** Generates a fresh v1 Notification Key. */
        fun generateKey(random: SecureRandom = SecureRandom()): ByteArray =
            ByteArray(KEY_BYTES).also(random::nextBytes)

        /** Production factory; tests inject [InMemoryEncryptedRecordStore] directly. */
        fun create(context: Context): NotificationKeyStore = NotificationKeyStore(
            AndroidKeystoreRecordStore(context, "dev.bybee.heeler.notification-keys"),
        )

        private fun account(hostId: UUID): String = "$ACCOUNT_PREFIX$hostId"
    }
}

sealed class NotificationKeyStoreError(message: String, cause: Throwable? = null) : Exception(message, cause) {
    data object InvalidRecord : NotificationKeyStoreError("Notification Key record is invalid")
    class StorageFailure(cause: EncryptedRecordStoreException) :
        NotificationKeyStoreError("Notification Key storage is unavailable", cause)
}

private fun uuidFromStringOrNull(value: String): UUID? = try {
    UUID.fromString(value)
} catch (_: IllegalArgumentException) {
    null
}
