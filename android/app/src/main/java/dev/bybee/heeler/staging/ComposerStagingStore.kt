package dev.bybee.heeler.staging

import android.content.Context
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.bybee.heeler.core.transport.AttachmentStageProgress
import dev.bybee.heeler.core.transport.AttachmentStagingError
import dev.bybee.heeler.core.transport.PreparedFile
import dev.bybee.heeler.core.transport.PreparedImage
import dev.bybee.heeler.core.transport.Transport
import dev.bybee.heeler.core.transport.TransportError
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Whether the operation currently concerns an image or a document. */
enum class AttachmentMedium { IMAGE, FILE }

/** A user-actionable staging failure. */
data class StagingFailure(
    val medium: AttachmentMedium,
    val message: String,
    val isRetryable: Boolean,
)

/**
 * State for the Composer's one-at-a-time attachment workflow. A completed Host
 * file deliberately has no cleanup action here: it is outside the app's
 * ownership boundary (ADR 0005).
 */
sealed interface ComposerStagingState {
    data object Idle : ComposerStagingState
    data class Preparing(val medium: AttachmentMedium) : ComposerStagingState
    data class Uploading(
        val medium: AttachmentMedium,
        val progress: AttachmentStageProgress,
    ) : ComposerStagingState
    data class Failed(val failure: StagingFailure) : ComposerStagingState
    data class BackgroundInterrupted(val failure: StagingFailure) : ComposerStagingState
    data class Completed(
        val medium: AttachmentMedium,
        val remotePath: String,
    ) : ComposerStagingState
}

val ComposerStagingState.isBusy: Boolean
    get() = this is ComposerStagingState.Preparing || this is ComposerStagingState.Uploading

/** Failures produced before an attachment reaches the transport boundary. */
sealed class ImagePreparationError(message: String) : Exception(message) {
    data object SelectionUnavailable : ImagePreparationError("The selected photo is no longer available.")
    data object InvalidImage : ImagePreparationError("The selected item is not a readable image.")
    data object SourceTooLarge : ImagePreparationError("The selected image is too large to decode safely.")
    data object UnableToProduceBoundedOutput :
        ImagePreparationError("The image could not be reduced below the 16 MiB upload limit.")

    data object LocalStorageFailed :
        ImagePreparationError("Heeler couldn't prepare the image in protected local storage.")
}

sealed class FilePreparationError(message: String) : Exception(message) {
    data object SelectionUnavailable : FilePreparationError("The selected file is no longer available.")
    data object SourceTooLarge : FilePreparationError("The selected file exceeds the 64 MiB upload limit.")
    data object LocalStorageFailed :
        FilePreparationError("Heeler couldn't prepare the file in protected local storage.")
}

/**
 * Coordinates Android photo/document selection with preparation and SFTP
 * staging. [transportProvider] is deliberately a narrow boundary so an Agent
 * Detail screen can bind the currently selected Host without duplicating
 * connection ownership.
 */
class ComposerStagingStore(
    context: Context,
    private val transportProvider: suspend () -> Transport,
    private val imagePreparer: AndroidImagePreparer = AndroidImagePreparer(context.applicationContext),
    private val filePreparer: AndroidFilePreparer = AndroidFilePreparer(context.applicationContext),
) : ViewModel() {
    private sealed interface Source {
        val medium: AttachmentMedium
        data class Image(val uri: Uri) : Source { override val medium = AttachmentMedium.IMAGE }
        data class File(val uri: Uri) : Source { override val medium = AttachmentMedium.FILE }
    }

    private sealed interface RetainedPrepared {
        val medium: AttachmentMedium
        val byteCount: Long
        fun delete()

        data class Image(val image: PreparedImage) : RetainedPrepared {
            override val medium = AttachmentMedium.IMAGE
            override val byteCount = image.byteCount
            override fun delete() {
                image.file.delete()
            }
        }

        data class File(val file: PreparedFile) : RetainedPrepared {
            override val medium = AttachmentMedium.FILE
            override val byteCount = file.byteCount
            override fun delete() {
                file.file.delete()
            }
        }
    }

    private enum class CancellationDisposition { USER, BACKGROUND }

    private val _state = MutableStateFlow<ComposerStagingState>(ComposerStagingState.Idle)
    val state: StateFlow<ComposerStagingState> = _state.asStateFlow()

    private var operation: Job? = null
    private var operationId = 0L
    private var cancellationDisposition: CancellationDisposition? = null
    private var retainedPrepared: RetainedPrepared? = null
    private var retryInsertion: ((String) -> Unit)? = null

    /** Starts photo staging. The callback receives an absolute Host path plus one trailing space. */
    fun stageImage(uri: Uri, onInserted: (String) -> Unit) = begin(Source.Image(uri), onInserted)

    /** Starts document staging. The callback receives an absolute Host path plus one trailing space. */
    fun stageFile(uri: Uri, onInserted: (String) -> Unit) = begin(Source.File(uri), onInserted)

    /** Cancels in-flight local work and preserves the prepared source only for foreground retry. */
    fun cancel() {
        if (!state.value.isBusy) return
        cancellationDisposition = CancellationDisposition.USER
        operation?.cancel()
    }

    /** Call from the owning screen's process lifecycle observer before backgrounding. */
    fun onBackgrounded() {
        if (!state.value.isBusy) return
        cancellationDisposition = CancellationDisposition.BACKGROUND
        operation?.cancel()
    }

    /** Resumes a failed upload from the app-owned local copy when retry is valid. */
    fun retry() {
        val failure = when (val current = state.value) {
            is ComposerStagingState.Failed -> current.failure
            is ComposerStagingState.BackgroundInterrupted -> current.failure
            else -> return
        }
        val prepared = retainedPrepared ?: return
        if (!failure.isRetryable || prepared.medium != failure.medium || operation != null) return

        cancellationDisposition = null
        val id = ++operationId
        _state.value = ComposerStagingState.Uploading(
            prepared.medium,
            AttachmentStageProgress(0, prepared.byteCount),
        )
        operation = viewModelScope.launch { upload(prepared, id, retryInsertion) }
    }

    /** Drops a completed or non-busy state and deletes only the app-owned prepared file. */
    fun dismiss() {
        if (state.value.isBusy) return
        discardPrepared()
        retryInsertion = null
        _state.value = ComposerStagingState.Idle
    }

    private fun begin(source: Source, onInserted: (String) -> Unit) {
        if (state.value.isBusy || operation != null) return
        discardPrepared()
        retryInsertion = onInserted
        cancellationDisposition = null
        val id = ++operationId
        _state.value = ComposerStagingState.Preparing(source.medium)
        operation = viewModelScope.launch {
            try {
                val prepared = prepare(source)
                if (id != operationId) {
                    prepared.delete()
                    return@launch
                }
                retainedPrepared = prepared
                _state.value = ComposerStagingState.Uploading(
                    prepared.medium,
                    AttachmentStageProgress(0, prepared.byteCount),
                )
                upload(prepared, id, onInserted)
            } catch (error: Throwable) {
                finishError(error, source.medium, id)
            }
        }
    }

    private suspend fun prepare(source: Source): RetainedPrepared = when (source) {
        is Source.Image -> RetainedPrepared.Image(imagePreparer.prepare(source.uri))
        is Source.File -> RetainedPrepared.File(filePreparer.prepare(source.uri))
    }

    private suspend fun upload(
        prepared: RetainedPrepared,
        id: Long,
        onInserted: ((String) -> Unit)?,
    ) {
        try {
            val transport = transportProvider()
            val path = when (prepared) {
                is RetainedPrepared.Image -> transport.stageImage(prepared.image) { progress ->
                    withContext(Dispatchers.Main.immediate) {
                        if (id == operationId && _state.value is ComposerStagingState.Uploading) {
                            _state.value = ComposerStagingState.Uploading(prepared.medium, progress)
                        }
                    }
                }.path
                is RetainedPrepared.File -> transport.stageFile(prepared.file) { progress ->
                    withContext(Dispatchers.Main.immediate) {
                        if (id == operationId && _state.value is ComposerStagingState.Uploading) {
                            _state.value = ComposerStagingState.Uploading(prepared.medium, progress)
                        }
                    }
                }.path
            }
            if (id != operationId) return
            operation = null
            cancellationDisposition = null
            discardPrepared()
            _state.value = ComposerStagingState.Completed(prepared.medium, path)
            // Insertion is strictly local draft editing; it must never write an Enter byte.
            onInserted?.invoke("$path ")
        } catch (error: Throwable) {
            finishError(error, prepared.medium, id)
        }
    }

    private fun finishError(error: Throwable, medium: AttachmentMedium, id: Long) {
        if (id != operationId) return
        operation = null
        if (error is CancellationException || error === AttachmentStagingError.Cancelled ||
            error === TransportError.Cancelled
        ) {
            when (cancellationDisposition) {
                CancellationDisposition.BACKGROUND -> {
                    _state.value = ComposerStagingState.BackgroundInterrupted(
                        StagingFailure(
                            medium,
                            "${medium.displayName} upload paused when Heeler moved to the background.",
                            retainedPrepared != null,
                        ),
                    )
                }
                CancellationDisposition.USER, null -> {
                    discardPrepared()
                    retryInsertion = null
                    _state.value = ComposerStagingState.Idle
                }
            }
            cancellationDisposition = null
            return
        }

        val failure = failureFor(error, medium)
        if (!failure.isRetryable) {
            discardPrepared()
            retryInsertion = null
        }
        _state.value = ComposerStagingState.Failed(failure)
    }

    private fun discardPrepared() {
        retainedPrepared?.delete()
        retainedPrepared = null
    }

    override fun onCleared() {
        operationId++
        operation?.cancel()
        operation = null
        discardPrepared()
        super.onCleared()
    }
}

private val AttachmentMedium.displayName: String
    get() = if (this == AttachmentMedium.IMAGE) "Image" else "File"

private fun failureFor(error: Throwable, medium: AttachmentMedium): StagingFailure = when (error) {
    is TransportError.SshUnreachable -> StagingFailure(
        medium,
        "The Host is not connected. Reconnect, then retry the upload.",
        true,
    )
    AttachmentStagingError.SftpUnavailable -> StagingFailure(
        medium,
        "SFTP is unavailable on this Host. Enable its SSH SFTP subsystem.",
        false,
    )
    is AttachmentStagingError -> StagingFailure(
        medium,
        "${medium.displayName} upload failed.",
        error.isRetryable,
    )
    is ImagePreparationError, is FilePreparationError -> StagingFailure(
        medium,
        error.message ?: "${medium.displayName} preparation failed.",
        false,
    )
    else -> StagingFailure(medium, "${medium.displayName} preparation failed.", false)
}

/** Android Photo Picker and SAF document picker wiring for a Composer attachment menu. */
@Composable
fun ComposerAttachmentPickerLaunchers(
    store: ComposerStagingStore,
    onInserted: (String) -> Unit,
    content: @Composable (pickPhoto: () -> Unit, pickFile: () -> Unit) -> Unit,
) {
    val currentOnInserted by rememberUpdatedState(onInserted)
    val photoPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia(),
    ) { uri -> uri?.let { store.stageImage(it, currentOnInserted) } }
    val documentPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri -> uri?.let { store.stageFile(it, currentOnInserted) } }
    content(
        { photoPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
        { documentPicker.launch(arrayOf("*/*")) },
    )
}

/** Small status surface for the Composer's Add menu; callers may place it anywhere in their screen. */
@Composable
fun ComposerStagingStatus(
    state: ComposerStagingState,
    onCancel: () -> Unit,
    onRetry: () -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    when (state) {
        ComposerStagingState.Idle -> Unit
        is ComposerStagingState.Preparing -> StagingRow(
            text = "Preparing ${state.medium.displayName}…",
            progress = null,
            primaryLabel = "Cancel",
            onPrimary = onCancel,
            onSecondary = null,
            modifier = modifier,
        )
        is ComposerStagingState.Uploading -> StagingRow(
            text = "Uploading ${state.medium.displayName}… ${(state.progress.fractionCompleted * 100).toInt()}%",
            progress = state.progress.fractionCompleted.toFloat(),
            primaryLabel = "Cancel",
            onPrimary = onCancel,
            onSecondary = null,
            modifier = modifier,
        )
        is ComposerStagingState.Failed -> StagingRow(
            text = state.failure.message,
            progress = null,
            primaryLabel = if (state.failure.isRetryable) "Retry" else "Dismiss",
            onPrimary = if (state.failure.isRetryable) onRetry else onDismiss,
            onSecondary = if (state.failure.isRetryable) onDismiss else null,
            modifier = modifier,
        )
        is ComposerStagingState.BackgroundInterrupted -> StagingRow(
            text = state.failure.message,
            progress = null,
            primaryLabel = if (state.failure.isRetryable) "Retry" else "Dismiss",
            onPrimary = if (state.failure.isRetryable) onRetry else onDismiss,
            onSecondary = if (state.failure.isRetryable) onDismiss else null,
            modifier = modifier,
        )
        is ComposerStagingState.Completed -> StagingRow(
            text = "${state.medium.displayName} path inserted.",
            progress = null,
            primaryLabel = "Dismiss",
            onPrimary = onDismiss,
            onSecondary = null,
            modifier = modifier,
        )
    }
}

@Composable
private fun StagingRow(
    text: String,
    progress: Float?,
    primaryLabel: String,
    onPrimary: () -> Unit,
    onSecondary: (() -> Unit)?,
    modifier: Modifier,
) {
    Column(modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(text)
        progress?.let { LinearProgressIndicator(progress = { it }, modifier = Modifier.fillMaxWidth()) }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(onClick = onPrimary) { Text(primaryLabel) }
            onSecondary?.let { OutlinedButton(onClick = it) { Text("Dismiss") } }
        }
    }
}

