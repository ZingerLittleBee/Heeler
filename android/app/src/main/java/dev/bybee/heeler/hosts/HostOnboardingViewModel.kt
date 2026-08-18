package dev.bybee.heeler.hosts

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.bybee.heeler.core.crypto.DeviceKeyStore
import dev.bybee.heeler.core.crypto.DeviceKeyStoreError
import dev.bybee.heeler.core.transport.HeelerSshTransport
import dev.bybee.heeler.core.transport.HostKeyCandidate
import dev.bybee.heeler.core.transport.HostKeyPolicy
import dev.bybee.heeler.core.transport.HerdrSession
import dev.bybee.heeler.core.transport.SharedPreferencesKnownHostsStore
import dev.bybee.heeler.core.transport.SshCredentials
import dev.bybee.heeler.core.transport.SshJumpSettings
import dev.bybee.heeler.core.transport.SshTransportSettings
import dev.bybee.heeler.core.transport.TransportError
import dev.bybee.heeler.data.Host
import dev.bybee.heeler.data.HostAuth
import dev.bybee.heeler.data.HostStore
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

enum class PreflightCheck(val title: String) {
    Connection("SSH connection"),
    RemoteEnvironment("Remote environment"),
    HerdrInstalled("herdr installed"),
    ServerRunning("herdr server running"),
    ProtocolCompatible("Protocol compatible"),
}

sealed interface PreflightCheckStatus {
    data object Passed : PreflightCheckStatus
    data class Failed(val hint: String) : PreflightCheckStatus
    data object Blocked : PreflightCheckStatus
}

data class PreflightReport(private val failed: Pair<PreflightCheck, String>? = null) {
    fun status(check: PreflightCheck): PreflightCheckStatus {
        val failure = failed ?: return PreflightCheckStatus.Passed
        val failedIndex = PreflightCheck.entries.indexOf(failure.first)
        return when (PreflightCheck.entries.indexOf(check).compareTo(failedIndex)) {
            -1 -> PreflightCheckStatus.Passed
            0 -> PreflightCheckStatus.Failed(failure.second)
            else -> PreflightCheckStatus.Blocked
        }
    }

    companion object {
        val AllPassed = PreflightReport()
        fun failed(check: PreflightCheck, hint: String) = PreflightReport(check to hint)
    }
}

enum class PreflightPhase { Idle, Running, Finished }

data class HostKeyReplacement(
    val known: dev.bybee.heeler.core.transport.HostKeyFingerprint,
    val presented: dev.bybee.heeler.core.transport.HostKeyFingerprint,
    val endpointAddress: String,
    val endpointPort: Int,
    val targetEndpoint: Boolean,
)

data class HostOnboardingUiState(
    val phase: PreflightPhase = PreflightPhase.Idle,
    val report: PreflightReport? = null,
    val serverVersion: String? = null,
    val protocolVersion: Int? = null,
    val protocolIsNewerThanApp: Boolean = false,
    val availableSessions: List<HerdrSession> = emptyList(),
    val sessionDiscoveryError: String? = null,
    val pendingFingerprint: HostKeyCandidate? = null,
    val pendingReplacement: HostKeyReplacement? = null,
)

/**
 * Runs a short-lived connect/discover/ping preflight. The Console retains long-lived connections;
 * this ViewModel only owns an onboarding probe and the explicit 60-second trust decision.
 */
class HostOnboardingViewModel(
    context: Context,
    private val hostStore: HostStore,
    initialHost: Host,
    private val deviceKeys: DeviceKeyStore = DeviceKeyStore.create(context.applicationContext),
    private val knownHosts: SharedPreferencesKnownHostsStore = SharedPreferencesKnownHostsStore(
        context.applicationContext.getSharedPreferences(KNOWN_HOSTS_PREFERENCES, Context.MODE_PRIVATE),
    ),
) : ViewModel() {
    private val _state = MutableStateFlow(HostOnboardingUiState())
    val state: StateFlow<HostOnboardingUiState> = _state.asStateFlow()
    private var host = initialHost
    private var fingerprintDecision: CompletableDeferred<Boolean>? = null

    fun updateHost(updated: Host) {
        host = updated
    }

    fun runChecks() {
        if (_state.value.phase == PreflightPhase.Running) return
        val target = host
        viewModelScope.launch {
            _state.value = HostOnboardingUiState(phase = PreflightPhase.Running)
            val credentials = try {
                credentialsFor(target)
            } catch (error: PreflightCredentialError) {
                _state.value = _state.value.copy(
                    phase = PreflightPhase.Finished,
                    report = PreflightReport.failed(PreflightCheck.Connection, error.message.orEmpty()),
                )
                return@launch
            }
            val policy = HostKeyPolicy(
                knownHosts = knownHosts,
                confirmFirstConnect = { candidate -> requestFingerprintDecision(target, candidate) },
            )
            val settings = SshTransportSettings(
                host = target.address,
                port = target.port,
                username = target.username,
                credentials = credentials.value,
                hostKeyPolicy = policy,
                socket = target.socketLocation(),
                jump = target.jumpHost?.let { jump ->
                    SshJumpSettings(
                        host = jump.address,
                        port = jump.port,
                        username = jump.username,
                        credentials = credentials.value,
                    )
                },
            )
            try {
                val transport = withContext(Dispatchers.IO) { HeelerSshTransport.connect(settings) }
                try {
                    val discovery = try {
                        Result.success(withContext(Dispatchers.IO) { transport.listSessions() })
                    } catch (error: Throwable) {
                        Result.failure(error)
                    }
                    val sessions = discovery.getOrDefault(emptyList())
                    val discoveryError = discovery.exceptionOrNull()?.let {
                        "Could not discover herdr sessions. You can still enter a session name manually."
                    }
                    val server = withContext(Dispatchers.IO) { transport.ping() }
                    _state.value = _state.value.copy(
                        phase = PreflightPhase.Finished,
                        report = PreflightReport.AllPassed,
                        serverVersion = server.version,
                        protocolVersion = server.protocolVersion,
                        protocolIsNewerThanApp = server.exceedsGeneratedProtocol,
                        availableSessions = sessions,
                        sessionDiscoveryError = discoveryError,
                    )
                } catch (error: Throwable) {
                    _state.value = _state.value.copy(
                        phase = PreflightPhase.Finished,
                        report = reportFor(error, target),
                        pendingReplacement = replacementFor(error, target),
                    )
                } finally {
                    try {
                        transport.close()
                    } catch (_: Throwable) {
                        // The probe outcome is already set.
                    }
                }
            } catch (error: Throwable) {
                _state.value = _state.value.copy(
                    phase = PreflightPhase.Finished,
                    report = reportFor(error, target),
                    pendingReplacement = replacementFor(error, target),
                )
            } finally {
                credentials.clear()
            }
        }
    }

    /** Completes the current first-connect dialog. An unanswered dialog is declined after 60s. */
    fun confirmFingerprint(trust: Boolean) {
        fingerprintDecision?.complete(trust)
    }

    /** Persists a selectable running session and immediately repeats preflight on that socket. */
    fun selectSession(session: HerdrSession) {
        val selected = host.copy(sessionName = session.name.takeUnless { session.isDefault })
        viewModelScope.launch {
            try {
                hostStore.update(selected)
                host = selected
                runChecks()
            } catch (_: Throwable) {
                _state.value = _state.value.copy(
                    sessionDiscoveryError = "The selected session could not be saved.",
                )
            }
        }
    }

    /** Explicitly replaces a mismatched key at its exact endpoint, then proves it by rerunning. */
    fun trustReplacement() {
        val replacement = _state.value.pendingReplacement ?: return
        viewModelScope.launch {
            try {
                knownHosts.setFingerprint(
                    replacement.presented,
                    replacement.endpointAddress,
                    replacement.endpointPort,
                )
                if (replacement.targetEndpoint) {
                    val updated = host.copy(hostKeyFingerprint = replacement.presented.displayString)
                    hostStore.update(updated)
                    host = updated
                }
                _state.value = _state.value.copy(pendingReplacement = null)
                runChecks()
            } catch (_: Throwable) {
                _state.value = _state.value.copy(
                    sessionDiscoveryError = "The new Host key could not be saved.",
                )
            }
        }
    }

    private suspend fun requestFingerprintDecision(target: Host, candidate: HostKeyCandidate): Boolean {
        val targetEndpoint = candidate.host == target.address && candidate.port == target.port
        if (targetEndpoint && target.hostKeyFingerprint.isNotEmpty()) {
            return candidate.fingerprint.displayString == target.hostKeyFingerprint
        }
        if (fingerprintDecision != null) return false
        val decision = CompletableDeferred<Boolean>()
        fingerprintDecision = decision
        _state.value = _state.value.copy(pendingFingerprint = candidate)
        val accepted = withTimeoutOrNull(FINGERPRINT_TIMEOUT_MS) { decision.await() } == true
        fingerprintDecision = null
        _state.value = _state.value.copy(pendingFingerprint = null)
        if (!accepted || !targetEndpoint || target.hostKeyFingerprint.isNotEmpty()) return accepted
        val pinned = target.copy(hostKeyFingerprint = candidate.fingerprint.displayString)
        return try {
            hostStore.update(pinned)
            host = pinned
            true
        } catch (_: Throwable) {
            false
        }
    }

    private suspend fun credentialsFor(target: Host): EphemeralCredentials = when (target.auth) {
        HostAuth.DeviceKey -> {
            val key = try {
                withContext(Dispatchers.IO) { deviceKeys.loadOrCreate() }
            } catch (_: DeviceKeyStoreError.StoredKeyCorrupt) {
                throw PreflightCredentialError("The Device Key is corrupted. Replace it, then install the new public key on every Device Key Host.")
            } catch (_: DeviceKeyStoreError.StorageFailure) {
                throw PreflightCredentialError("The Device Key could not be loaded from secure storage.")
            }
            val privateKey = key.openSshPrivateKeyPem("heeler").encodeToByteArray()
            val publicKey = key.openSshPublicKey("heeler").encodeToByteArray()
            EphemeralCredentials(SshCredentials.PublicKey(privateKey, publicKey)) {
                privateKey.fill(0)
                publicKey.fill(0)
            }
        }
        is HostAuth.Password -> {
            val password = try {
                hostStore.password(target)
            } catch (_: Throwable) {
                throw PreflightCredentialError("The saved password could not be read from secure storage.")
            } ?: throw PreflightCredentialError("No password is saved for this Host. Edit it and enter one.")
            EphemeralCredentials(SshCredentials.Password(password)) { password.fill('\u0000') }
        }
    }

    private fun reportFor(error: Throwable, target: Host): PreflightReport {
        val transport = error as? TransportError
            ?: return PreflightReport.failed(PreflightCheck.Connection, "The connection failed unexpectedly.")
        val authHint = if (target.auth is HostAuth.DeviceKey) {
            "The Host rejected the Device Key. Copy its authorized_keys line to ~/.ssh/authorized_keys, then run checks again."
        } else {
            "The Host rejected the login. Check the username and password."
        }
        return when (transport) {
            is TransportError.SshUnreachable -> PreflightReport.failed(
                PreflightCheck.Connection,
                "Could not reach the Host over SSH. Check its address and port. (${transport.detail})",
            )
            is TransportError.JumpHostFailed -> PreflightReport.failed(
                PreflightCheck.Connection,
                "Could not reach the Jump Host. ${transport.underlying.message.orEmpty()}",
            )
            TransportError.TcpForwardingUnavailable -> PreflightReport.failed(
                PreflightCheck.Connection,
                "The Jump Host refused TCP forwarding. Enable AllowTcpForwarding and run checks again.",
            )
            TransportError.AuthenticationFailed -> PreflightReport.failed(PreflightCheck.Connection, authHint)
            TransportError.DeviceKeyCorrupt -> PreflightReport.failed(
                PreflightCheck.Connection,
                "The Device Key is corrupted. Replace it and install the new public key on every Device Key Host.",
            )
            is TransportError.HostKeyRejected -> PreflightReport.failed(
                PreflightCheck.Connection,
                "The Host key was not confirmed. Run checks again and verify the fingerprint.",
            )
            is TransportError.HostKeyMismatch -> PreflightReport.failed(
                PreflightCheck.Connection,
                "Host key changed. Verify the presented fingerprint with the Host owner before trusting it.",
            )
            is TransportError.SocketNotFound -> PreflightReport.failed(
                PreflightCheck.HerdrInstalled,
                "No herdr socket exists at ${transport.path}. Install/start herdr or correct the session name.",
            )
            is TransportError.HomeDirectoryUnresolvable -> PreflightReport.failed(
                PreflightCheck.RemoteEnvironment,
                "The remote home directory could not be resolved. (${transport.detail})",
            )
            is TransportError.StreamLocalOpenFailed -> PreflightReport.failed(
                PreflightCheck.ServerRunning,
                "Could not open ${transport.path}. Start herdr or enable SSH stream-local forwarding.",
            )
            is TransportError.ProtocolVersionMismatch -> PreflightReport.failed(
                PreflightCheck.ProtocolCompatible,
                "herdr protocol ${transport.server} is too old; this app needs at least ${transport.supported}.",
            )
            TransportError.TimedOut -> PreflightReport.failed(
                PreflightCheck.Connection,
                "The Host did not answer in time. Check the connection and try again.",
            )
            TransportError.Cancelled -> PreflightReport.failed(PreflightCheck.Connection, "The check was cancelled.")
            is TransportError.MalformedResponse -> PreflightReport.failed(
                PreflightCheck.ProtocolCompatible,
                "The server response did not parse as herdr protocol. (${transport.detail})",
            )
            is TransportError.ApiRejected -> PreflightReport.failed(
                PreflightCheck.ServerRunning,
                "herdr rejected the check: ${transport.serverMessage} (${transport.code}).",
            )
            is TransportError.ChannelFailed -> PreflightReport.failed(
                PreflightCheck.Connection,
                "The connection failed unexpectedly. (${transport.detail})",
            )
            TransportError.EventsChannelAlreadyOpen,
            TransportError.TerminalChannelAlreadyOpen -> PreflightReport.failed(
                PreflightCheck.Connection,
                "The connection is busy. Try again.",
            )
        }
    }

    private fun replacementFor(error: Throwable, target: Host): HostKeyReplacement? {
        val direct = error as? TransportError.HostKeyMismatch
        if (direct != null) {
            return HostKeyReplacement(
                known = direct.known,
                presented = direct.presented,
                endpointAddress = target.address,
                endpointPort = target.port,
                targetEndpoint = true,
            )
        }
        val jumpMismatch = (error as? TransportError.JumpHostFailed)?.underlying
            as? TransportError.HostKeyMismatch
            ?: return null
        val jump = target.jumpHost ?: return null
        return HostKeyReplacement(
            known = jumpMismatch.known,
            presented = jumpMismatch.presented,
            endpointAddress = jump.address,
            endpointPort = jump.port,
            targetEndpoint = false,
        )
    }

    private class PreflightCredentialError(message: String) : Exception(message)

    private class EphemeralCredentials(
        val value: SshCredentials,
        private val clearValue: () -> Unit,
    ) {
        fun clear() = clearValue()
    }

    private companion object {
        const val FINGERPRINT_TIMEOUT_MS = 60_000L
        const val KNOWN_HOSTS_PREFERENCES = "heeler-known-hosts"
    }
}

private fun Host.socketLocation(): dev.bybee.heeler.core.transport.HerdrSocketLocation =
    sessionName?.let(dev.bybee.heeler.core.transport.HerdrSocketLocation::NamedSession)
        ?: dev.bybee.heeler.core.transport.HerdrSocketLocation.DefaultSession
