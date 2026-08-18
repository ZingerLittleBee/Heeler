package dev.bybee.heeler.core.crypto

import android.content.Context

/**
 * Loads the device's long-lived Ed25519 key, generating it exactly once. A corrupt stored key is
 * never silently replaced because doing so would revoke this device's SSH access on every Host.
 */
class DeviceKeyStore(
    private val storage: EncryptedRecordStore,
    private val account: String = DEFAULT_ACCOUNT,
) {
    fun loadOrCreate(): DeviceKey {
        val stored = readStored() ?: return createAndStore()
        try {
            return DeviceKey.fromSeed(stored) ?: throw DeviceKeyStoreError.StoredKeyCorrupt
        } finally {
            stored.fill(0)
        }
    }

    /** Replaces the identity only for an explicit, user-approved recovery flow. */
    fun replaceStoredKey(): DeviceKey = createAndStore()

    private fun createAndStore(): DeviceKey {
        val key = DeviceKey.generate()
        val seed = key.seedForStorage()
        try {
            writeStored(seed)
        } finally {
            seed.fill(0)
        }
        return key
    }

    private fun readStored(): ByteArray? = try {
        storage.read(account)
    } catch (error: EncryptedRecordStoreException.Corrupt) {
        throw DeviceKeyStoreError.StoredKeyCorrupt
    } catch (error: EncryptedRecordStoreException) {
        throw DeviceKeyStoreError.StorageFailure(error)
    }

    private fun writeStored(seed: ByteArray) {
        try {
            storage.write(account, seed)
        } catch (error: EncryptedRecordStoreException) {
            throw DeviceKeyStoreError.StorageFailure(error)
        }
    }

    companion object {
        const val DEFAULT_ACCOUNT = "device-ed25519-private-key"

        /** Production factory; tests inject [InMemoryEncryptedRecordStore] directly. */
        fun create(context: Context): DeviceKeyStore = DeviceKeyStore(
            AndroidKeystoreRecordStore(context, "dev.bybee.heeler.device-key"),
        )
    }
}

sealed class DeviceKeyStoreError(message: String, cause: Throwable? = null) : Exception(message, cause) {
    data object StoredKeyCorrupt : DeviceKeyStoreError("Stored device key is corrupt")
    class StorageFailure(cause: EncryptedRecordStoreException) :
        DeviceKeyStoreError("Device key storage is unavailable", cause)
}
