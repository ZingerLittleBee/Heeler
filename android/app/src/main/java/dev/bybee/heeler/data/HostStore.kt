package dev.bybee.heeler.data

import android.content.Context
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import dev.bybee.heeler.core.crypto.AndroidKeystoreRecordStore
import dev.bybee.heeler.core.crypto.EncryptedRecordStore
import dev.bybee.heeler.core.crypto.EncryptedRecordStoreException
import java.io.IOException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerializationException
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

private val Context.hostCatalogDataStore by preferencesDataStore(name = "heeler-host-catalog")
private val hostCatalogKey = stringPreferencesKey("catalog")

/** Host catalog failures. Corrupt data is never overwritten by a later mutation. */
sealed class HostStoreError(message: String, cause: Throwable? = null) : Exception(message, cause) {
    data object UnknownHost : HostStoreError("The Host no longer exists.")
    data object DuplicateHost : HostStoreError("A Host with this id already exists.")
    data object CatalogUnreadable : HostStoreError("The saved Host catalog cannot be read.")
    data object PasswordRequired : HostStoreError("A password is required for password authentication.")
    class StorageUnavailable(cause: Throwable) : HostStoreError("Host storage is unavailable.", cause)
}

/**
 * Encrypted password-record boundary. Passwords are never part of the DataStore JSON catalog.
 * Callers own returned character arrays and must erase them when they no longer need them.
 */
class HostPasswordStore(private val records: EncryptedRecordStore) {
    fun read(reference: String): CharArray? = try {
        records.read(reference)?.let { bytes ->
            try {
                bytes.toString(Charsets.UTF_8).toCharArray()
            } finally {
                bytes.fill(0)
            }
        }
    } catch (error: EncryptedRecordStoreException) {
        throw HostStoreError.StorageUnavailable(error)
    }

    fun write(reference: String, password: CharArray) {
        val bytes = password.concatToString().encodeToByteArray()
        try {
            records.write(reference, bytes)
        } catch (error: EncryptedRecordStoreException) {
            throw HostStoreError.StorageUnavailable(error)
        } finally {
            bytes.fill(0)
        }
    }

    fun remove(reference: String) {
        try {
            records.remove(reference)
        } catch (error: EncryptedRecordStoreException) {
            throw HostStoreError.StorageUnavailable(error)
        }
    }
}

/**
 * DataStore-backed catalog with a versioned JSON envelope. The catalog is intentionally small and
 * is observed as one immutable list; passwords are kept in [HostPasswordStore] by record ref.
 */
class HostStore(
    context: Context,
    records: EncryptedRecordStore = AndroidKeystoreRecordStore(context, PASSWORD_SERVICE),
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) {
    private val dataStore = context.applicationContext.hostCatalogDataStore
    private val passwords = HostPasswordStore(records)
    private val mutex = Mutex()
    private val loaded = CompletableDeferred<Unit>()
    private val _hosts = MutableStateFlow<List<Host>>(emptyList())
    private val _loadError = MutableStateFlow<HostStoreError?>(null)

    /** The catalog ordered by insertion; connection and console layers choose their own sorting. */
    val hosts: StateFlow<List<Host>> = _hosts.asStateFlow()
    val loadError: StateFlow<HostStoreError?> = _loadError.asStateFlow()

    init {
        scope.launch {
            dataStore.data
                .catch { error ->
                    _loadError.value = HostStoreError.StorageUnavailable(error)
                    if (!loaded.isCompleted) loaded.complete(Unit)
                    if (error is IOException) emit(emptyPreferences()) else throw error
                }
                .collect(::applyPreferences)
        }
    }

    /** Adds a Host and, for password authentication, the corresponding encrypted password record. */
    suspend fun add(host: Host, password: CharArray? = null) = withContext(Dispatchers.IO) {
        mutate { current ->
            if (current.any { it.id == host.id }) throw HostStoreError.DuplicateHost
            applyPassword(host, password, isNew = true)
            current + host
        }
    }

    /**
     * Replaces one Host. A null password preserves an existing password; changing to Device Key
     * always removes the old record so credentials do not linger after the auth mode changes.
     */
    suspend fun update(host: Host, password: CharArray? = null) = withContext(Dispatchers.IO) {
        mutate { current ->
            val index = current.indexOfFirst { it.id == host.id }
            if (index < 0) throw HostStoreError.UnknownHost
            applyPassword(host, password, isNew = false)
            current.toMutableList().also { it[index] = host }
        }
    }

    /** Removes a Host and its encrypted password record. */
    suspend fun remove(id: String) = withContext(Dispatchers.IO) {
        mutate { current ->
            val host = current.firstOrNull { it.id == id } ?: throw HostStoreError.UnknownHost
            passwordReference(host.id).also(passwords::remove)
            current.filterNot { it.id == id }
        }
    }

    /** Loads the password for connection setup, or null when no record exists. */
    suspend fun password(host: Host): CharArray? = withContext(Dispatchers.IO) {
        val reference = (host.auth as? HostAuth.Password)?.recordRef ?: return@withContext null
        passwords.read(reference)
    }

    private suspend fun mutate(change: (List<Host>) -> List<Host>) = mutex.withLock {
        loaded.await()
        _loadError.value?.let { throw it }
        val next = change(_hosts.value)
        try {
            dataStore.edit { preferences ->
                preferences[hostCatalogKey] = json.encodeToString(CatalogEnvelope(VERSION, next))
            }
            _hosts.value = next
        } catch (error: HostStoreError) {
            throw error
        } catch (error: Throwable) {
            throw HostStoreError.StorageUnavailable(error)
        }
    }

    private fun applyPassword(host: Host, supplied: CharArray?, isNew: Boolean) {
        when (val auth = host.auth) {
            HostAuth.DeviceKey -> passwords.remove(passwordReference(host.id))
            is HostAuth.Password -> {
                require(auth.recordRef == passwordReference(host.id)) {
                    "Host password reference must be derived from the Host id."
                }
                if (supplied == null) {
                    if (isNew) throw HostStoreError.PasswordRequired
                } else {
                    passwords.write(auth.recordRef, supplied)
                }
            }
        }
    }

    private fun applyPreferences(preferences: Preferences) {
        val raw = preferences[hostCatalogKey]
        if (raw == null) {
            _hosts.value = emptyList()
            _loadError.value = null
            if (!loaded.isCompleted) loaded.complete(Unit)
            return
        }
        try {
            val envelope = json.decodeFromString<CatalogEnvelope>(raw)
            if (envelope.version != VERSION) throw HostStoreError.CatalogUnreadable
            _hosts.value = envelope.hosts
            _loadError.value = null
        } catch (_: SerializationException) {
            _loadError.value = HostStoreError.CatalogUnreadable
        } catch (_: IllegalArgumentException) {
            _loadError.value = HostStoreError.CatalogUnreadable
        } catch (_: HostStoreError) {
            _loadError.value = HostStoreError.CatalogUnreadable
        } finally {
            if (!loaded.isCompleted) loaded.complete(Unit)
        }
    }

    @Serializable
    private data class CatalogEnvelope(val version: Int, val hosts: List<Host>)

    companion object {
        const val VERSION = 1
        private const val PASSWORD_SERVICE = "dev.bybee.heeler.host-password"
        private val json = Json { encodeDefaults = true; ignoreUnknownKeys = false }

        /** Stable record name shared by form, connection, and deletion paths. */
        fun passwordReference(hostId: String): String = "host-password-$hostId"
    }
}
