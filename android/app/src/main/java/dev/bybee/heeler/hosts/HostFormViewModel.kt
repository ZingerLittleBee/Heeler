package dev.bybee.heeler.hosts

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.bybee.heeler.core.crypto.DeviceKeyStore
import dev.bybee.heeler.core.crypto.DeviceKeyStoreError
import dev.bybee.heeler.core.transport.HerdrSessionName
import dev.bybee.heeler.data.Host
import dev.bybee.heeler.data.HostAuth
import dev.bybee.heeler.data.HostStore
import dev.bybee.heeler.data.JumpHostSpec
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

enum class HostAuthenticationMode { DeviceKey, Password }

data class HostFormUiState(
    val displayName: String = "",
    val address: String = "",
    val port: String = Host.DEFAULT_PORT.toString(),
    val username: String = "",
    val authentication: HostAuthenticationMode = HostAuthenticationMode.DeviceKey,
    val password: String = "",
    val sessionName: String = "",
    val jumpAddress: String = "",
    val jumpPort: String = Host.DEFAULT_PORT.toString(),
    val jumpUsername: String = "",
    val hostKeyFingerprint: String = "",
    val authorizedKeyLine: String? = null,
    val deviceKeyError: DeviceKeyPresentation? = null,
    val saving: Boolean = false,
    val saveError: String? = null,
    val savedHost: Host? = null,
) {
    val usesJumpHost: Boolean get() = jumpAddress.trim().isNotEmpty()

    fun canSave(editing: Host?): Boolean {
        val parsedPort = port.toValidPort() ?: return false
        if (address.trim().isEmpty() || username.trim().isEmpty()) return false
        val normalizedSession = sessionName.trim()
        if (normalizedSession.isNotEmpty() && !HerdrSessionName.isValid(normalizedSession)) return false
        if (usesJumpHost && jumpPort.toValidPort() == null) return false
        return authentication != HostAuthenticationMode.Password || password.isNotEmpty() ||
            editing?.auth is HostAuth.Password
    }
}

enum class DeviceKeyPresentation {
    Corrupt,
    Unavailable,
}

/** Form behavior and validation for both `host/new` and an existing Host edit route. */
class HostFormViewModel(
    context: Context,
    private val hostStore: HostStore,
    private val editing: Host? = null,
    private val deviceKeys: DeviceKeyStore = DeviceKeyStore.create(context.applicationContext),
) : ViewModel() {
    private val _state = MutableStateFlow(editing.toFormState())
    val state: StateFlow<HostFormUiState> = _state.asStateFlow()

    init {
        loadDeviceKey()
    }

    fun update(transform: (HostFormUiState) -> HostFormUiState) {
        if (_state.value.saving) return
        _state.value = transform(_state.value).copy(saveError = null, savedHost = null)
    }

    fun loadDeviceKey() {
        viewModelScope.launch {
            val outcome = withContext(Dispatchers.IO) {
                try {
                    DeviceKeyPresentationResult.Line(deviceKeys.loadOrCreate().openSshPublicKey("heeler"))
                } catch (_: DeviceKeyStoreError.StoredKeyCorrupt) {
                    DeviceKeyPresentationResult.Error(DeviceKeyPresentation.Corrupt)
                } catch (_: DeviceKeyStoreError.StorageFailure) {
                    DeviceKeyPresentationResult.Error(DeviceKeyPresentation.Unavailable)
                }
            }
            _state.value = when (outcome) {
                is DeviceKeyPresentationResult.Line -> _state.value.copy(
                    authorizedKeyLine = outcome.value,
                    deviceKeyError = null,
                )
                is DeviceKeyPresentationResult.Error -> _state.value.copy(
                    authorizedKeyLine = null,
                    deviceKeyError = outcome.value,
                )
            }
        }
    }

    /** Invoked only after the screen's destructive confirmation. */
    fun replaceDeviceKey() {
        viewModelScope.launch {
            val outcome = withContext(Dispatchers.IO) {
                try {
                    DeviceKeyPresentationResult.Line(deviceKeys.replaceStoredKey().openSshPublicKey("heeler"))
                } catch (_: DeviceKeyStoreError.StoredKeyCorrupt) {
                    DeviceKeyPresentationResult.Error(DeviceKeyPresentation.Corrupt)
                } catch (_: DeviceKeyStoreError.StorageFailure) {
                    DeviceKeyPresentationResult.Error(DeviceKeyPresentation.Unavailable)
                }
            }
            _state.value = when (outcome) {
                is DeviceKeyPresentationResult.Line -> _state.value.copy(
                    authorizedKeyLine = outcome.value,
                    deviceKeyError = null,
                )
                is DeviceKeyPresentationResult.Error -> _state.value.copy(deviceKeyError = outcome.value)
            }
        }
    }

    fun save() {
        val beforeSave = _state.value
        if (!beforeSave.canSave(editing)) return
        val draftedHost = beforeSave.toHost(editing?.id ?: UUID.randomUUID().toString()) ?: return
        val host = if (editing != null && (
                draftedHost.address != editing.address ||
                    draftedHost.port != editing.port ||
                    draftedHost.jumpHost != editing.jumpHost
            )
        ) {
            draftedHost.copy(hostKeyFingerprint = "")
        } else {
            draftedHost
        }
        viewModelScope.launch {
            _state.value = _state.value.copy(saving = true, saveError = null)
            val suppliedPassword = beforeSave.password.takeIf {
                beforeSave.authentication == HostAuthenticationMode.Password && it.isNotEmpty()
            }?.toCharArray()
            try {
                if (editing == null) {
                    hostStore.add(host, suppliedPassword)
                } else {
                    hostStore.update(host, suppliedPassword)
                }
                _state.value = _state.value.copy(
                    saving = false,
                    password = "",
                    savedHost = host,
                )
            } catch (_: Throwable) {
                _state.value = _state.value.copy(
                    saving = false,
                    saveError = "The Host could not be saved. Check storage and try again.",
                )
            } finally {
                suppliedPassword?.fill('\u0000')
            }
        }
    }

    fun consumeSavedHost() {
        _state.value = _state.value.copy(savedHost = null)
    }

    private sealed interface DeviceKeyPresentationResult {
        data class Line(val value: String) : DeviceKeyPresentationResult
        data class Error(val value: DeviceKeyPresentation) : DeviceKeyPresentationResult
    }
}

private fun Host?.toFormState(): HostFormUiState = this?.let { host ->
    HostFormUiState(
        displayName = host.displayName.orEmpty(),
        address = host.address,
        port = host.port.toString(),
        username = host.username,
        authentication = if (host.auth is HostAuth.Password) {
            HostAuthenticationMode.Password
        } else {
            HostAuthenticationMode.DeviceKey
        },
        sessionName = host.sessionName.orEmpty(),
        jumpAddress = host.jumpHost?.address.orEmpty(),
        jumpPort = host.jumpHost?.port?.toString() ?: Host.DEFAULT_PORT.toString(),
        jumpUsername = host.jumpHost?.username.orEmpty(),
        hostKeyFingerprint = host.hostKeyFingerprint,
    )
} ?: HostFormUiState()

private fun HostFormUiState.toHost(id: String): Host? {
    val hostPort = port.toValidPort() ?: return null
    val normalizedAddress = address.trim()
    val normalizedUsername = username.trim()
    if (normalizedAddress.isEmpty() || normalizedUsername.isEmpty()) return null
    val jump = jumpAddress.trim().takeIf(String::isNotEmpty)?.let { jumpAddress ->
        JumpHostSpec(
            address = jumpAddress,
            port = jumpPort.toValidPort() ?: return null,
            username = jumpUsername.trim().ifEmpty { normalizedUsername },
        )
    }
    return Host(
        id = id,
        displayName = displayName.trim().ifEmpty { null },
        address = normalizedAddress,
        port = hostPort,
        username = normalizedUsername,
        auth = when (authentication) {
            HostAuthenticationMode.DeviceKey -> HostAuth.DeviceKey
            HostAuthenticationMode.Password -> HostAuth.Password(HostStore.passwordReference(id))
        },
        sessionName = sessionName.trim().ifEmpty { null },
        jumpHost = jump,
        hostKeyFingerprint = hostKeyFingerprint,
    )
}


private fun String.toValidPort(): Int? = toIntOrNull()?.takeIf { it in 1..65535 }
