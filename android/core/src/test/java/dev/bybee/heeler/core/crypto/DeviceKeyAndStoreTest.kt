package dev.bybee.heeler.core.crypto

import java.io.ByteArrayInputStream
import java.io.DataInputStream
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test

class DeviceKeyAndStoreTest {
    @Test
    fun ed25519OpenSshPublicAndPrivateEncodingsRoundTrip() {
        val key = DeviceKey.generate()
        val publicLine = key.openSshPublicKey("heeler test")
        val fields = publicLine.split(" ", limit = 3)
        assertEquals(listOf(DeviceKey.KEY_TYPE, Base64.getEncoder().encodeToString(key.publicKeyBlob), "heeler test"), fields)
        assertArrayEquals(key.publicKeyBlob, parsePublicBlob(fields[1]))

        val pem = key.openSshPrivateKeyPem("heeler test")
        val encoded = pem
            .removePrefix("-----BEGIN OPENSSH PRIVATE KEY-----\n")
            .removeSuffix("\n-----END OPENSSH PRIVATE KEY-----\n")
            .replace("\n", "")
        val reader = SshReader(Base64.getDecoder().decode(encoded))
        assertArrayEquals("openssh-key-v1\u0000".toByteArray(Charsets.US_ASCII), reader.raw(15))
        assertEquals("none", reader.string().toString(Charsets.US_ASCII))
        assertEquals("none", reader.string().toString(Charsets.US_ASCII))
        assertEquals(0, reader.string().size)
        assertEquals(1, reader.uint32())
        assertArrayEquals(key.publicKeyBlob, reader.string())

        val privateBlock = SshReader(reader.string())
        assertEquals(privateBlock.uint32(), privateBlock.uint32())
        assertEquals(DeviceKey.KEY_TYPE, privateBlock.string().toString(Charsets.US_ASCII))
        assertArrayEquals(key.publicKeyBytes, privateBlock.string())
        val privateAndPublic = privateBlock.string()
        assertEquals(64, privateAndPublic.size)
        assertArrayEquals(key.publicKeyBytes, privateAndPublic.copyOfRange(32, 64))
        assertEquals("heeler test", privateBlock.string().toString(Charsets.US_ASCII))
        var padding = 1
        while (privateBlock.remaining > 0) assertEquals(padding++, privateBlock.byte())
        assertEquals(0, reader.remaining)
    }

    @Test
    fun deviceKeyStoreKeepsOneIdentityAndRejectsCorruption() {
        val storage = InMemoryEncryptedRecordStore()
        val store = DeviceKeyStore(storage)
        val first = store.loadOrCreate()
        val second = store.loadOrCreate()
        assertEquals(first.openSshPublicKey("device"), second.openSshPublicKey("device"))

        storage.write(DeviceKeyStore.DEFAULT_ACCOUNT, ByteArray(31))
        try {
            store.loadOrCreate()
            fail("corrupt key was silently replaced")
        } catch (_: DeviceKeyStoreError.StoredKeyCorrupt) {
            // Expected: replacing a key here would invalidate all enrolled Hosts.
        }
    }

    @Test
    fun pairingSeedCreatesTheExpectedEphemeralDeviceKey() {
        val storage = InMemoryEncryptedRecordStore()
        val enrolledIdentity = DeviceKeyStore(storage).loadOrCreate()
        val seed = storage.read(DeviceKeyStore.DEFAULT_ACCOUNT)!!
        try {
            val bootstrapIdentity = DeviceKey.fromSeed(seed) ?: error("stored 32-byte seed was rejected")
            assertEquals(
                enrolledIdentity.openSshPublicKey("pairing"),
                bootstrapIdentity.openSshPublicKey("pairing"),
            )
        } finally {
            seed.fill(0)
        }
    }

    @Test
    fun notificationKeyStoreUsesHostScopedKidLookup() {
        val store = NotificationKeyStore(InMemoryEncryptedRecordStore())
        val first = NotificationKeyRecord(UUID.randomUUID(), "First Host", ByteArray(32) { it.toByte() })
        val second = NotificationKeyRecord(UUID.randomUUID(), "Second Host", ByteArray(32) { (it + 1).toByte() })
        store.save(first)
        store.save(second)

        assertEquals(first, store.recordForHost(first.hostId))
        assertEquals(second, store.recordForKeyId(second.keyId))
        assertNotEquals(first.keyId, second.keyId)
        store.removeRecord(first.hostId)
        assertNull(store.recordForHost(first.hostId))
        assertEquals(second, store.recordForKeyId(second.keyId))
    }

    @Test
    fun hostKeyFingerprintUsesOpenSshSha256Presentation() {
        val blob = byteArrayOf(0, 0, 0, 11) + "ssh-ed25519".toByteArray(Charsets.US_ASCII) + ByteArray(32)
        val expected = "SHA256:" + Base64.getEncoder().withoutPadding()
            .encodeToString(MessageDigest.getInstance("SHA-256").digest(blob))
        assertEquals(expected, HostKeyFingerprint.fromHostKeyBlob(blob).value)
        assertEquals(expected, HostKeyFingerprint.parse(expected)?.value)
    }

    private fun parsePublicBlob(encoded: String): ByteArray {
        val blob = Base64.getDecoder().decode(encoded)
        val reader = SshReader(blob)
        assertEquals(DeviceKey.KEY_TYPE, reader.string().toString(Charsets.US_ASCII))
        assertEquals(32, reader.string().size)
        assertEquals(0, reader.remaining)
        return blob
    }
}

private class SshReader(private val bytes: ByteArray) {
    private val input = DataInputStream(ByteArrayInputStream(bytes))

    val remaining: Int get() = input.available()

    fun uint32(): Int = input.readInt()

    fun string(): ByteArray = raw(uint32())

    fun raw(length: Int): ByteArray {
        require(length in 0..remaining) { "invalid SSH binary length" }
        return ByteArray(length).also(input::readFully)
    }

    fun byte(): Int = input.readUnsignedByte()
}
