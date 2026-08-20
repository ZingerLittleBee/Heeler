package dev.bybee.heeler.detail

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.CreationExtras
import dev.bybee.heeler.connection.HostConnectionManager
import dev.bybee.heeler.core.terminal.NativeTerminal
import dev.bybee.heeler.core.transport.TerminalAttachRequest
import dev.bybee.heeler.core.transport.TerminalAttachSession
import dev.bybee.heeler.core.transport.TransportError
import dev.bybee.heeler.core.transport.connectionGuidance
import dev.bybee.heeler.core.wire.AgentSendKeysParams
import dev.bybee.heeler.terminal.TerminalSnapshot
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

sealed interface AttachStatus {
    data object AwaitingSize : AttachStatus
    data object Connecting : AttachStatus
    data object Live : AttachStatus
    data object Ended : AttachStatus
    data class Failed(val message: String) : AttachStatus
}

data class AgentAttachUiState(
    val status: AttachStatus = AttachStatus.AwaitingSize,
    val terminalHandle: Long = 0,
    val snapshot: TerminalSnapshot = emptyTerminalSnapshot(),
    val links: List<AttachLink> = emptyList(),
    val controlError: String? = null,
)

private data class TerminalGeometry(
    val cols: Int,
    val rows: Int,
    val cellWidthPx: Int,
    val cellHeightPx: Int,
)

private class AttachPipeline(
    val handle: Long,
    var session: TerminalAttachSession? = null,
)

/**
 * Owns one Agent Attach lifecycle. A pipeline is intentionally complete: its
 * native VT instance, PTY session, output collector, and geometry move together
 * when a Host reconnects. NativeTerminal is confined to viewModelScope's main
 * dispatcher because its handles are not thread safe.
 */
class AgentAttachStore(
    private val hostId: String,
    private val paneId: String,
    private val connections: HostConnectionManager,
) : ViewModel() {
    private val mutableUiState = MutableStateFlow(AgentAttachUiState())
    val uiState = mutableUiState.asStateFlow()

    private val linkIndex = AttachLinkIndex()
    private var geometry: TerminalGeometry? = null
    private var pipeline: AttachPipeline? = null
    private val cleanupScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var openingJob: Job? = null
    private var tearingDown = false
    private var restartAfterTeardown = false
    private var left = false
    private var observedGeneration = connections.generation(hostId)

    /** Starts Attach only after [onTerminalResize] has reported a real grid. */
    fun onTerminalResize(
        cols: Int,
        rows: Int,
        cellWidthPx: Int,
        cellHeightPx: Int,
    ) {
        if (cols <= 0 || rows <= 0 || cellWidthPx <= 0 || cellHeightPx <= 0 || left) return
        val updated = TerminalGeometry(cols, rows, cellWidthPx, cellHeightPx)
        val changed = geometry != updated
        geometry = updated
        val current = pipeline
        if (current == null) {
            startPipelineIfPossible()
            return
        }
        if (!changed) return
        NativeTerminal.resize(current.handle, cols, rows, cellWidthPx, cellHeightPx)
        publishSnapshot(current)
        current.session?.resize(cols, rows)
    }

    /** The console's monotonic Host generation changed, so replace everything. */
    fun onConnectionGenerationChanged(generation: Long) {
        if (generation == observedGeneration) return
        observedGeneration = generation
        replacePipeline(restart = true)
    }

    /** Recreates an Attach that ended remotely or failed after a live session. */
    fun reattach() = replacePipeline(restart = true)

    /** Keep the native scrollback responsive without sending authored input. */
    fun scrollTerminal(delta: Int, x: Float, y: Float) {
        val current = pipeline ?: return
        NativeTerminal.scroll(current.handle, delta, x, y)
        // On the alternate screen (or with mouse reporting on) the native VT
        // answers a scroll with bytes for the remote application instead of
        // moving local scrollback. Flush them now — the output collector only
        // drains this buffer when the *next* remote bytes arrive, which never
        // happens while an idle TUI waits for exactly this input. The scroll
        // path is lossy and coalesced so momentum never delays real typing.
        val remoteScroll = NativeTerminal.drainPtyWrites(current.handle)
        if (remoteScroll.isNotEmpty()) current.session?.scroll(remoteScroll, rows = 1)
        publishSnapshot(current)
    }
    fun refreshTerminalAppearance() {
        pipeline?.let(::publishSnapshot)
    }


    /** Supplements incremental PTY indexing when the canvas exposes visible text. */
    fun onViewportTextChanged(text: String) {
        if (left) return
        linkIndex.receiveViewportText(text)
        publishLinks()
    }

    /** Composer tools only: direct Agent key names, never raw terminal typing. */
    fun sendAgentKeys(keys: List<String>) {
        if (keys.isEmpty() || left) return
        viewModelScope.launch {
            runCatching {
                connections.transport(hostId).sendAgentKeys(AgentSendKeysParams(target = paneId, keys = keys))
            }.onSuccess {
                mutableUiState.update { it.copy(controlError = null) }
            }.onFailure { error ->
                if (error !is CancellationException) {
                    mutableUiState.update { it.copy(controlError = presentationFor(error)) }
                }
            }
        }
    }

    fun clearControlError() = mutableUiState.update { it.copy(controlError = null) }

    /** Explicit departure ends the PTY and forgets session-only Attach Links. */
    fun leave() {
        if (left) return
        left = true
        restartAfterTeardown = false
        linkIndex.clear()
        mutableUiState.update { it.copy(links = emptyList()) }
        replacePipeline(restart = false)
    }

    /** A retained ViewModel can reappear after a transient navigation transition. */
    fun rejoin() {
        if (!left) return
        left = false
        observedGeneration = connections.generation(hostId)
        if (tearingDown) {
            restartAfterTeardown = true
            return
        }
        startPipelineIfPossible()
    }

    private fun startPipelineIfPossible() {
        if (left || tearingDown || pipeline != null) return
        val size = geometry ?: return
        val handle = NativeTerminal.create(size.cols, size.rows, MAX_SCROLLBACK_LINES)
        val created = AttachPipeline(handle)
        pipeline = created
        NativeTerminal.resize(handle, size.cols, size.rows, size.cellWidthPx, size.cellHeightPx)
        publishSnapshot(created)
        mutableUiState.update { it.copy(status = AttachStatus.Connecting, terminalHandle = handle, controlError = null) }

        openingJob = viewModelScope.launch {
            try {
                val transport = connections.transport(hostId)
                val session = transport.attachTerminal(
                    TerminalAttachRequest(target = paneId, takeover = true, cols = size.cols, rows = size.rows),
                )
                if (pipeline !== created || left) {
                    session.end()
                    return@launch
                }
                created.session = session
                mutableUiState.update { it.copy(status = AttachStatus.Live) }
                session.output.collect { bytes ->
                    if (pipeline !== created || left) return@collect
                    NativeTerminal.writeRemote(created.handle, bytes)
                    linkIndex.receive(bytes)
                    val terminalWrites = NativeTerminal.drainPtyWrites(created.handle)
                    if (terminalWrites.isNotEmpty()) session.send(terminalWrites)
                    publishSnapshot(created)
                    publishLinks()
                }
                if (pipeline === created && !left) {
                    created.session = null
                    linkIndex.finishOutput()
                    mutableUiState.update { it.copy(status = AttachStatus.Ended, links = linkIndex.links) }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (pipeline === created && !left) {
                    mutableUiState.update { it.copy(status = AttachStatus.Failed(presentationFor(error))) }
                }
            }
        }
    }

    /**
     * Serializes the old terminal channel's explicit close before a replacement
     * opens, preserving the Host's one-terminal-channel invariant.
     */
    private fun replacePipeline(restart: Boolean) {
        restartAfterTeardown = restartAfterTeardown || restart
        val previous = pipeline
        if (previous == null) {
            if (!tearingDown && restartAfterTeardown && !left) {
                restartAfterTeardown = false
                startPipelineIfPossible()
            }
            return
        }
        pipeline = null
        openingJob?.cancel()
        openingJob = null
        if (restart && !left) {
            mutableUiState.update { it.copy(status = AttachStatus.Connecting, terminalHandle = 0) }
        } else {
            mutableUiState.update { it.copy(status = AttachStatus.AwaitingSize, terminalHandle = 0) }
        }
        if (tearingDown) return
        tearingDown = true
        viewModelScope.launch {
            try {
                previous.session?.end()
            } catch (_: CancellationException) {
                // The successor must still be allowed to create its terminal.
            } catch (_: Throwable) {
                // A closed remote channel is already released; destroy local state.
            } finally {
                NativeTerminal.destroy(previous.handle)
                tearingDown = false
                if (restartAfterTeardown && !left) {
                    restartAfterTeardown = false
                    startPipelineIfPossible()
                }
            }
        }
    }

    private fun publishSnapshot(current: AttachPipeline) {
        if (pipeline !== current) return
        val snapshot = runCatching {
            TerminalSnapshot.fromByteBuffer(
                NativeTerminal.snapshot(current.handle),
                TerminalSnapshot.parseImages(NativeTerminal.snapshotImages(current.handle)),
            )
        }.getOrNull() ?: return
        mutableUiState.update { it.copy(snapshot = snapshot, terminalHandle = current.handle) }
    }

    private fun publishLinks() = mutableUiState.update { it.copy(links = linkIndex.links) }

    override fun onCleared() {
        left = true
        linkIndex.clear()
        val current = pipeline
        pipeline = null
        openingJob?.cancel()
        if (current != null) {
            NativeTerminal.destroy(current.handle)
            current.session?.let { session ->
                cleanupScope.launch { runCatching { session.end() } }
            }
        }
        super.onCleared()
    }

    companion object {
        private const val MAX_SCROLLBACK_LINES = 10_000

        fun factory(
            hostId: String,
            paneId: String,
            connections: HostConnectionManager,
        ): ViewModelProvider.Factory = object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>, extras: CreationExtras): T =
                AgentAttachStore(hostId, paneId, connections) as T
        }
    }
}

private fun presentationFor(error: Throwable): String = when (error) {
    is TransportError -> error.connectionGuidance
    else -> error.message?.takeIf(String::isNotBlank) ?: "The Host did not accept the request. Try again."
}

private fun emptyTerminalSnapshot(cols: Int = 80, rows: Int = 24): TerminalSnapshot {
    val cellCount = cols * rows
    return TerminalSnapshot(
        cols = cols,
        rows = rows,
        cursorX = 0,
        cursorY = 0,
        cursorVisible = false,
        defaultBgArgb = 0xFF000000.toInt(),
        defaultFgArgb = 0xFFE6E1E5.toInt(),
        codepoints = IntArray(cellCount),
        fgArgb = IntArray(cellCount),
        bgArgb = IntArray(cellCount),
        flags = ByteArray(cellCount),
    )
}
