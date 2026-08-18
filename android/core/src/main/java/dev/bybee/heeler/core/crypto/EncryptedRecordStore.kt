package dev.bybee.heeler.core.crypto

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.security.GeneralSecurityException
import java.security.KeyStore
import java.security.MessageDigest
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * A small, injectable encrypted-record abstraction. Production implementations keep every value
 * in an app-private file authenticated and encrypted by a non-exportable Android Keystore key.
 */
interface EncryptedRecordStore {
    @Throws(EncryptedRecordStoreException::class)
    fun read(account: String): ByteArray?

    @Throws(EncryptedRecordStoreException::class)
    fun write(account: String, value: ByteArray)

    @Throws(EncryptedRecordStoreException::class)
    fun remove(account: String)

    @Throws(EncryptedRecordStoreException::class)
    fun accounts(): Set<String>
}

/** Failures of the encrypted-at-rest boundary, never translated by matching a message string. */
sealed class EncryptedRecordStoreException(message: String, cause: Throwable? = null) :
    Exception(message, cause) {
    class Corrupt(cause: Throwable? = null) :
        EncryptedRecordStoreException("Encrypted record is corrupt", cause)

    class Unavailable(cause: Throwable) :
        EncryptedRecordStoreException("Android Keystore storage is unavailable", cause)
}

/** Test-only-safe in-memory implementation; values are copied at every boundary. */
class InMemoryEncryptedRecordStore : EncryptedRecordStore {
    private val records = linkedMapOf<String, ByteArray>()

    @Synchronized
    override fun read(account: String): ByteArray? = records[account]?.copyOf()

    @Synchronized
    override fun write(account: String, value: ByteArray) {
        records[account] = value.copyOf()
    }

    @Synchronized
    override fun remove(account: String) {
        records.remove(account)
    }

    @Synchronized
    override fun accounts(): Set<String> = records.keys.toSet()
}

/**
 * App-private, per-record Android Keystore storage. One AES-256-GCM Keystore key is scoped to
 * [service]; each logical record has a separate atomically-written ciphertext and is bound to its
 * account name as GCM associated data. Neither private keys nor notification keys hit disk plain.
 */
class AndroidKeystoreRecordStore(context: Context, private val service: String) : EncryptedRecordStore {
    private val appContext = context.applicationContext
    private val directory = File(
        appContext.filesDir,
        "heeler-secure/${fileComponent(service)}",
    )

    init {
        if (!directory.exists() && !directory.mkdirs()) {
            throw EncryptedRecordStoreException.Unavailable(IOException("Cannot create secure storage directory"))
        }
        if (!directory.isDirectory) {
            throw EncryptedRecordStoreException.Unavailable(IOException("Secure storage path is not a directory"))
        }
    }

    @Synchronized
    override fun read(account: String): ByteArray? {
        requireAccount(account)
        return readEncrypted(account)
    }

    @Synchronized
    override fun write(account: String, value: ByteArray) {
        requireAccount(account)
        val currentAccounts = readIndex()
        writeEncrypted(account, value)
        if (currentAccounts.add(account)) writeIndex(currentAccounts)
    }

    @Synchronized
    override fun remove(account: String) {
        requireAccount(account)
        val currentAccounts = readIndex()
        val file = fileFor(account)
        if (file.exists() && !file.delete()) {
            throw EncryptedRecordStoreException.Unavailable(IOException("Cannot remove encrypted record"))
        }
        if (currentAccounts.remove(account)) writeIndex(currentAccounts)
    }

    @Synchronized
    override fun accounts(): Set<String> = readIndex()

    private fun readIndex(): LinkedHashSet<String> {
        val raw = readEncrypted(INDEX_ACCOUNT) ?: return linkedSetOf()
        return try {
            val input = DataInputStream(ByteArrayInputStream(raw))
            if (input.readInt() != INDEX_VERSION) throw IOException("Unsupported encrypted index version")
            val count = input.readInt()
            if (count !in 0..MAX_INDEX_ACCOUNTS) throw IOException("Invalid encrypted index size")
            LinkedHashSet<String>(count).apply {
                repeat(count) {
                    val length = input.readInt()
                    if (length !in 1..MAX_ACCOUNT_BYTES) throw IOException("Invalid account length")
                    val bytes = ByteArray(length)
                    input.readFully(bytes)
                    val account = Base64Url.decodeUtf8(bytes) ?: throw IOException("Invalid account encoding")
                    requireAccount(account)
                    add(account)
                }
                if (input.available() != 0) throw IOException("Unexpected encrypted index content")
            }
        } catch (error: IOException) {
            throw EncryptedRecordStoreException.Corrupt(error)
        } catch (error: IllegalArgumentException) {
            throw EncryptedRecordStoreException.Corrupt(error)
        }
    }

    private fun writeIndex(accounts: Set<String>) {
        val raw = ByteArrayOutputStream().use { bytes ->
            DataOutputStream(bytes).use { output ->
                output.writeInt(INDEX_VERSION)
                output.writeInt(accounts.size)
                accounts.forEach { account ->
                    val encoded = account.toByteArray(Charsets.UTF_8)
                    output.writeInt(encoded.size)
                    output.write(encoded)
                }
            }
            bytes.toByteArray()
        }
        writeEncrypted(INDEX_ACCOUNT, raw)
    }

    private fun readEncrypted(account: String): ByteArray? {
        val file = fileFor(account)
        if (!file.exists()) return null
        val encrypted = try {
            AtomicFile(file).openRead().use { it.readBytes() }
        } catch (error: FileNotFoundException) {
            return null
        } catch (error: IOException) {
            throw EncryptedRecordStoreException.Unavailable(error)
        }
        if (encrypted.size < 1 + NONCE_BYTES + TAG_BYTES || encrypted[0] != FORMAT_VERSION) {
            throw EncryptedRecordStoreException.Corrupt()
        }
        val nonce = encrypted.copyOfRange(1, 1 + NONCE_BYTES)
        val ciphertext = encrypted.copyOfRange(1 + NONCE_BYTES, encrypted.size)
        return try {
            Cipher.getInstance("AES/GCM/NoPadding").apply {
                init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(TAG_BYTES * 8, nonce))
                updateAAD(aad(account))
            }.doFinal(ciphertext)
        } catch (error: GeneralSecurityException) {
            throw EncryptedRecordStoreException.Corrupt(error)
        }
    }

    private fun writeEncrypted(account: String, value: ByteArray) {
        // Android Keystore prohibits caller-supplied GCM nonces unless the key
        // opts out of randomized encryption (CALLER_NONCE_PROHIBITED). Let the
        // Keystore mint the IV and persist what it chose.
        val cipher = try {
            Cipher.getInstance("AES/GCM/NoPadding").apply {
                init(Cipher.ENCRYPT_MODE, key())
                updateAAD(aad(account))
            }
        } catch (error: GeneralSecurityException) {
            throw EncryptedRecordStoreException.Unavailable(error)
        }
        val nonce = cipher.iv
        if (nonce.size != NONCE_BYTES) {
            throw EncryptedRecordStoreException.Unavailable(
                GeneralSecurityException("Keystore produced a ${nonce.size}-byte GCM IV; expected $NONCE_BYTES"),
            )
        }
        val ciphertext = try {
            cipher.doFinal(value)
        } catch (error: GeneralSecurityException) {
            throw EncryptedRecordStoreException.Unavailable(error)
        }
        val output = ByteArray(1 + nonce.size + ciphertext.size)
        output[0] = FORMAT_VERSION
        nonce.copyInto(output, destinationOffset = 1)
        ciphertext.copyInto(output, destinationOffset = 1 + nonce.size)

        val atomicFile = AtomicFile(fileFor(account))
        var stream: java.io.FileOutputStream? = null
        try {
            stream = atomicFile.startWrite()
            stream.write(output)
            atomicFile.finishWrite(requireNotNull(stream))
        } catch (error: IOException) {
            stream?.let { atomicFile.failWrite(it) }
            throw EncryptedRecordStoreException.Unavailable(error)
        }
    }

    private fun key(): SecretKey {
        try {
            val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
            val existing = keyStore.getKey(keyAlias(), null) as? SecretKey
            if (existing != null) return existing
            val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
            generator.init(
                KeyGenParameterSpec.Builder(
                    keyAlias(),
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(KEY_BYTES * 8)
                    .build(),
            )
            return generator.generateKey()
        } catch (error: GeneralSecurityException) {
            throw EncryptedRecordStoreException.Unavailable(error)
        } catch (error: IOException) {
            throw EncryptedRecordStoreException.Unavailable(error)
        }
    }

    private fun fileFor(account: String): File = File(directory, fileComponent(account))

    private fun keyAlias(): String = "dev.bybee.heeler.crypto.${fileComponent(service)}"

    private fun aad(account: String): ByteArray =
        "HEELER-KEYSTORE-RECORD:$FORMAT_VERSION:$service:$account".toByteArray(Charsets.UTF_8)

    private fun requireAccount(account: String) {
        require(
            account.isNotEmpty() &&
                account != INDEX_ACCOUNT &&
                account.toByteArray(Charsets.UTF_8).size <= MAX_ACCOUNT_BYTES,
        ) {
            "Account must be a non-empty UTF-8 value of at most $MAX_ACCOUNT_BYTES bytes"
        }
    }

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val FORMAT_VERSION: Byte = 1
        const val INDEX_VERSION = 1
        const val NONCE_BYTES = 12
        const val TAG_BYTES = 16
        const val KEY_BYTES = 32
        const val MAX_INDEX_ACCOUNTS = 10_000
        const val MAX_ACCOUNT_BYTES = 4_096
        const val INDEX_ACCOUNT = "\u0000heeler-record-index"

        fun fileComponent(value: String): String {
            val digest = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
            return Base64.getUrlEncoder().withoutPadding().encodeToString(digest)
        }
    }
}
