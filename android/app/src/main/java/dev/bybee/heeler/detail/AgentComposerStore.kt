package dev.bybee.heeler.detail

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.CreationExtras
import dev.bybee.heeler.connection.HostConnectionManager
import dev.bybee.heeler.core.transport.TransportError
import dev.bybee.heeler.core.transport.connectionGuidance
import dev.bybee.heeler.core.wire.AgentPromptParams
import dev.bybee.heeler.core.wire.AgentStatus
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.util.UUID

sealed interface ComposerDeliveryState {
    data object Sending : ComposerDeliveryState
    data class Delivered(val progress: ComposerAgentProgress) : ComposerDeliveryState
    data class Failed(val message: String) : ComposerDeliveryState
}

enum class ComposerAgentProgress {
    Acknowledged,
    AgentBusy,
    Working,
    Done,
}

data class ComposerMessage(
    val id: String,
    val text: String,
    val sentWhileWorking: Boolean,
    val statusRevisionAtSend: Long,
    val observedWorkingAfterSend: Boolean = false,
    val state: ComposerDeliveryState = ComposerDeliveryState.Sending,
)

data class AgentComposerUiState(
    val draft: String = "",
    val selectionStart: Int = 0,
    val selectionEnd: Int = 0,
    val messages: List<ComposerMessage> = emptyList(),
) {
    val canSend: Boolean get() = draft.any { !it.isWhitespace() }
}

/**
 * Local Composer state. Changing the draft never calls Transport; [send] is
 * the sole delivery operation and one call produces exactly one agent.prompt.
 */
class AgentComposerStore(
    private val hostId: String,
    private val paneId: String,
    private val connections: HostConnectionManager,
) : ViewModel() {
    private val mutableUiState = MutableStateFlow(AgentComposerUiState())
    val uiState = mutableUiState.asStateFlow()

    private var agentStatus = AgentStatus.idle
    private var statusRevision = 0L

    fun setDraft(text: String, selectionStart: Int = text.length, selectionEnd: Int = selectionStart) {
        mutableUiState.value = AgentComposerUiState(
            draft = text,
            selectionStart = selectionStart.coerceIn(0, text.length),
            selectionEnd = selectionEnd.coerceIn(0, text.length),
            messages = mutableUiState.value.messages,
        )
    }

    /** Inserts exactly at the selection/cursor and deliberately never submits. */
    fun insertIntoDraft(text: String) {
        if (text.isEmpty()) return
        mutableUiState.update { state ->
            val start = minOf(state.selectionStart, state.selectionEnd).coerceIn(0, state.draft.length)
            val end = maxOf(state.selectionStart, state.selectionEnd).coerceIn(start, state.draft.length)
            val updated = state.draft.substring(0, start) + text + state.draft.substring(end)
            state.copy(draft = updated, selectionStart = start + text.length, selectionEnd = start + text.length)
        }
    }

    fun send() {
        val message = mutableUiState.value.run {
            if (!canSend) return
            ComposerMessage(
                id = UUID.randomUUID().toString(),
                text = draft,
                sentWhileWorking = agentStatus == AgentStatus.working,
                statusRevisionAtSend = statusRevision,
            )
        }
        mutableUiState.update { state ->
            state.copy(
                draft = "",
                selectionStart = 0,
                selectionEnd = 0,
                messages = state.messages + message,
            )
        }
        deliver(message.id)
    }

    fun retry(messageId: String) {
        val message = mutableUiState.value.messages.firstOrNull { it.id == messageId } ?: return
        if (message.state !is ComposerDeliveryState.Failed) return
        mutableUiState.update { state ->
            state.copy(messages = state.messages.map {
                if (it.id != messageId) it else it.copy(
                    sentWhileWorking = agentStatus == AgentStatus.working,
                    statusRevisionAtSend = statusRevision,
                    observedWorkingAfterSend = false,
                    state = ComposerDeliveryState.Sending,
                )
            })
        }
        deliver(messageId)
    }

    /** Removes a failed echo and places its original text before any new draft. */
    fun restoreFailedToDraft(messageId: String) {
        mutableUiState.update { state ->
            val failed = state.messages.firstOrNull { it.id == messageId && it.state is ComposerDeliveryState.Failed }
                ?: return@update state
            val restored = if (state.draft.isEmpty()) failed.text else "${failed.text}\n${state.draft}"
            state.copy(
                draft = restored,
                selectionStart = restored.length,
                selectionEnd = restored.length,
                messages = state.messages.filterNot { it.id == messageId },
            )
        }
    }

    /** Console events determine working/done; prompt acknowledgement never does. */
    fun onAgentStatusChanged(status: AgentStatus) {
        if (status == agentStatus) return
        agentStatus = status
        statusRevision += 1
        mutableUiState.update { state ->
            state.copy(messages = state.messages.map { message ->
                val sawWorking = message.observedWorkingAfterSend ||
                    (status == AgentStatus.working && message.statusRevisionAtSend != statusRevision)
                val nextState = when (val delivery = message.state) {
                    is ComposerDeliveryState.Delivered -> when {
                        status == AgentStatus.working && delivery.progress != ComposerAgentProgress.Done && sawWorking ->
                            ComposerDeliveryState.Delivered(ComposerAgentProgress.Working)
                        status == AgentStatus.done && (sawWorking || !message.sentWhileWorking) ->
                            ComposerDeliveryState.Delivered(ComposerAgentProgress.Done)
                        status == AgentStatus.idle && sawWorking ->
                            ComposerDeliveryState.Delivered(ComposerAgentProgress.Done)
                        else -> delivery
                    }
                    else -> delivery
                }
                message.copy(observedWorkingAfterSend = sawWorking, state = nextState)
            })
        }
    }

    private fun deliver(messageId: String) {
        viewModelScope.launch {
            val message = mutableUiState.value.messages.firstOrNull { it.id == messageId } ?: return@launch
            try {
                connections.transport(hostId).promptAgent(AgentPromptParams(target = paneId, text = message.text))
                mutableUiState.update { state ->
                    state.copy(messages = state.messages.map { current ->
                        if (current.id != messageId) current else current.copy(
                            state = ComposerDeliveryState.Delivered(progressAfterAcknowledgement(current)),
                        )
                    })
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                mutableUiState.update { state ->
                    state.copy(messages = state.messages.map { current ->
                        if (current.id != messageId) current else current.copy(
                            state = ComposerDeliveryState.Failed(composerErrorPresentation(error)),
                        )
                    })
                }
            }
        }
    }

    private fun progressAfterAcknowledgement(message: ComposerMessage): ComposerAgentProgress = when {
        message.observedWorkingAfterSend && agentStatus == AgentStatus.working -> ComposerAgentProgress.Working
        message.observedWorkingAfterSend && (agentStatus == AgentStatus.done || agentStatus == AgentStatus.idle) -> ComposerAgentProgress.Done
        !message.sentWhileWorking && message.statusRevisionAtSend != statusRevision && agentStatus == AgentStatus.done ->
            ComposerAgentProgress.Done
        message.sentWhileWorking -> ComposerAgentProgress.AgentBusy
        else -> ComposerAgentProgress.Acknowledged
    }

    companion object {
        fun factory(
            hostId: String,
            paneId: String,
            connections: HostConnectionManager,
        ): ViewModelProvider.Factory = object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>, extras: CreationExtras): T =
                AgentComposerStore(hostId, paneId, connections) as T
        }
    }
}

private fun composerErrorPresentation(error: Throwable): String = when (error) {
    is TransportError -> error.connectionGuidance
    else -> error.message?.takeIf(String::isNotBlank) ?: "The message could not be delivered. Try again."
}
