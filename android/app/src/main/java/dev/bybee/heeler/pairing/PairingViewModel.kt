package dev.bybee.heeler.pairing

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.bybee.heeler.core.crypto.DeviceKeyStore
import dev.bybee.heeler.core.crypto.DeviceKeyStoreError
import dev.bybee.heeler.core.crypto.PairingCode
import dev.bybee.heeler.core.crypto.PairingCodeError
import dev.bybee.heeler.data.Host
import dev.bybee.heeler.data.HostAuth
import dev.bybee.heeler.data.HostStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** User-facing, step-attributed outcome for a failed Pairing attempt. */
data class PairingFailure(
    val step: PairingStep,
    val message: String,
    val canRetry: Boolean,
)

data class PairingUiState(
    val scanned: Boolean = false,
    val isPairing: Boolean = false,
    val currentStep: PairingStep? = null,
    val scanError: String? = null,
    val failure: PairingFailure? = null,
    /** Non-null only after a successful verification and catalog write. */
    val pairedHost: Host? = null,
)

/**
 * Bridges QR recognition to the ceremony. Camera capture remains in the composable; all parsing,
 * persistence, expiry, recovery copy, and ceremony state are deterministic here.
 */
class PairingViewModel(
    context: Context,
    private val hostStore: HostStore,
    private val connector: PairingConnector = SshPairingConnector(),
    private val deviceKeys: DeviceKeyStore = DeviceKeyStore.create(context.applicationContext),
    private val nowSeconds: () -> Long = { System.currentTimeMillis() / 1_000 },
) : ViewModel() {
    private val _state = MutableStateFlow(PairingUiState())
    val state: StateFlow<PairingUiState> = _state.asStateFlow()

    private var parsedCode: PairingCode? = null
    private var attemptCode: PairingCode? = null
    private var enrolledViaBootstrap = false

    /** Accepts the first camera result only; scanner analysis is paused after it. */
    fun submitScanned(value: String) {
        if (parsedCode != null || _state.value.isPairing || _state.value.pairedHost != null) return
        val code = try {
            PairingCode.decode(value)
        } catch (error: PairingCodeError) {
            _state.value = _state.value.copy(scanError = parseMessage(error))
            return
        }
        parsedCode = code
        attemptCode = code
        enrolledViaBootstrap = false
        _state.value = _state.value.copy(scanned = true, scanError = null, failure = null)
        pair()
    }

    /** Repeats the current eligible ceremony without accepting another camera value. */
    fun pair() {
        val code = attemptCode ?: return
        if (_state.value.isPairing || _state.value.pairedHost != null) return
        viewModelScope.launch {
            _state.value = _state.value.copy(isPairing = true, currentStep = PairingStep.Parse, failure = null)
            try {
                if (code.bootstrap?.expiresAt?.let { it <= nowSeconds() } == true) {
                    _state.value = _state.value.copy(
                        failure = PairingFailure(PairingStep.Parse, EXPIRED_COPY, canRetry = false),
                    )
                    return@launch
                }
                val deviceKey = try {
                    deviceKeys.loadOrCreate()
                } catch (_: DeviceKeyStoreError.StoredKeyCorrupt) {
                    _state.value = _state.value.copy(
                        failure = PairingFailure(
                            PairingStep.Parse,
                            "This device's Device Key could not be loaded. Open Add Host to inspect or replace it.",
                            canRetry = false,
                        ),
                    )
                    return@launch
                } catch (_: DeviceKeyStoreError.StorageFailure) {
                    _state.value = _state.value.copy(
                        failure = PairingFailure(
                            PairingStep.Parse,
                            "This device's Device Key could not be loaded. Open Add Host to inspect or replace it.",
                            canRetry = false,
                        ),
                    )
                    return@launch
                }

                val result = try {
                    connector.pair(code, deviceKey) { step ->
                        _state.value = _state.value.copy(currentStep = step)
                    }
                } catch (error: CancellationException) {
                    throw error
                } catch (error: PairingCeremonyError) {
                    if (error is PairingCeremonyError.VerificationFailed && code.bootstrap != null) {
                        attemptCode = code.withoutBootstrap()
                        enrolledViaBootstrap = true
                    }
                    _state.value = _state.value.copy(
                        failure = failureFor(
                            error,
                            isConfigurationOnly = code.bootstrap == null && !enrolledViaBootstrap,
                        ),
                    )
                    return@launch
                } catch (_: Throwable) {
                    _state.value = _state.value.copy(
                        failure = PairingFailure(
                            PairingStep.Reach,
                            "Pairing stopped unexpectedly. Try again with the same Pairing Code.",
                            canRetry = true,
                        ),
                    )
                    return@launch
                }

                val host = Host(
                    address = result.address,
                    port = result.port,
                    username = result.username,
                    auth = HostAuth.DeviceKey,
                    hostKeyFingerprint = result.hostKeyFingerprint,
                )
                try {
                    hostStore.add(host)
                } catch (_: Throwable) {
                    _state.value = _state.value.copy(
                        failure = PairingFailure(
                            PairingStep.Verify,
                            "Pairing succeeded, but this device could not save the Host. Resolve Host storage, " +
                                "then generate a new Pairing Code and scan it again.",
                            canRetry = false,
                        ),
                    )
                    return@launch
                }
                _state.value = _state.value.copy(pairedHost = host)
            } finally {
                _state.value = _state.value.copy(isPairing = false, currentStep = null)
            }
        }
    }

    /** Returns to a fresh scanner only after the current ceremony has ended. */
    fun scanAgain() {
        if (_state.value.isPairing) return
        parsedCode = null
        attemptCode = null
        enrolledViaBootstrap = false
        _state.value = PairingUiState()
    }

    private fun PairingCode.withoutBootstrap(): PairingCode = PairingCode(
        addresses = addresses,
        port = port,
        username = username,
        hostKeyFingerprint = hostKeyFingerprint,
        bootstrap = null,
    )

    private fun parseMessage(error: PairingCodeError): String = when (error) {
        PairingCodeError.BadPrefix -> "That code is not a herdr Pairing Code."
        is PairingCodeError.UnsupportedVersion ->
            "This Pairing Code uses version ${error.found}, which this app does not understand. " +
                "Update the app and pairing plugin so they match."
        PairingCodeError.BadEncoding,
        PairingCodeError.BadPayload ->
            "The Pairing Code could not be read. Regenerate it in herdr and scan again."
    }

    private fun failureFor(
        error: PairingCeremonyError,
        isConfigurationOnly: Boolean,
    ): PairingFailure = when (error) {
        is PairingCeremonyError.HostUnreachable -> PairingFailure(
            PairingStep.Reach,
            "The Host did not answer at any address. Check that this device is on the same network " +
                "or VPN as the computer, then try again with the same Pairing Code.",
            canRetry = true,
        )
        PairingCeremonyError.BootstrapRejected -> PairingFailure(
            PairingStep.Authenticate,
            "The Host rejected this Pairing Code. It may have been used, expired, or its popup was " +
                "closed. Generate a new Pairing Code on the computer and scan it.",
            canRetry = false,
        )
        is PairingCeremonyError.EnrollmentRefused -> when (error.refusal) {
            EnrollmentRefusal.Expired -> PairingFailure(PairingStep.Enroll, EXPIRED_COPY, canRetry = false)
            EnrollmentRefusal.UnknownPairing -> PairingFailure(
                PairingStep.Enroll,
                "The Host has no Pairing in progress for this code. Generate a new Pairing Code and scan it.",
                canRetry = false,
            )
            EnrollmentRefusal.InvalidKey -> PairingFailure(
                PairingStep.Enroll,
                "The Host did not accept this Device Key. Try again; if it continues, update the app " +
                    "and pairing plugin so they match.",
                canRetry = true,
            )
            EnrollmentRefusal.NoInput -> PairingFailure(
                PairingStep.Enroll,
                "This device's key never reached the Host. Try again with the same Pairing Code.",
                canRetry = true,
            )
            is EnrollmentRefusal.Unrecognized -> PairingFailure(
                PairingStep.Enroll,
                "The Host refused Enrollment (${error.refusal.code}). Update the app and pairing plugin, " +
                    "then generate a new Pairing Code.",
                canRetry = false,
            )
        }
        is PairingCeremonyError.EnrollmentFailed -> PairingFailure(
            PairingStep.Enroll,
            "Enrollment did not complete, likely due to a network interruption. Try again with the same Pairing Code.",
            canRetry = true,
        )
        is PairingCeremonyError.VerificationFailed -> if (isConfigurationOnly) {
            PairingFailure(
                PairingStep.Verify,
                "The Host did not accept the Device Key, so it is not authorized there yet. Add this " +
                    "device's authorized_keys line on the Host, or generate a Pairing Code in herdr.",
                canRetry = false,
            )
        } else {
            PairingFailure(
                PairingStep.Verify,
                "This device was enrolled, but the verifying reconnect did not complete. Try again to finish with the enrolled key.",
                canRetry = true,
            )
        }
    }

    private companion object {
        const val EXPIRED_COPY = "This Pairing Code has expired. Generate a new one on the computer and scan it."
    }
}
