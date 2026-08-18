package dev.bybee.heeler.detail

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.CreationExtras
import dev.bybee.heeler.console.ConsoleAgent
import dev.bybee.heeler.console.ConsoleStore
import dev.bybee.heeler.core.transport.AgentLaunchRequest
import dev.bybee.heeler.core.transport.TransportError
import dev.bybee.heeler.core.transport.WorktreeSpec
import dev.bybee.heeler.core.transport.connectionGuidance
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

sealed interface DetailActionState {
    data object Idle : DetailActionState
    data object Running : DetailActionState
    data object Closed : DetailActionState
    data class WorktreeStarted(val paneId: String) : DetailActionState
    data class Failed(val message: String) : DetailActionState
}

/** Remote Agent-detail mutations kept out of the composable body. */
class AgentDetailActionsStore(
    private val consoleStore: ConsoleStore,
) : ViewModel() {
    private val mutableState = MutableStateFlow<DetailActionState>(DetailActionState.Idle)
    val state = mutableState.asStateFlow()

    fun rename(agent: ConsoleAgent, proposedName: String) {
        val name = proposedName.trim()
        if (!AGENT_NAME.matches(name)) {
            mutableState.value = DetailActionState.Failed(
                "Agent names start with a lowercase letter and use up to 32 lowercase letters, numbers, underscores, or hyphens.",
            )
            return
        }
        runUnitAction {
            consoleStore.renameAgent(hostId = agent.hostId, paneId = agent.paneId, name = name)
        }
    }

    fun close(agent: ConsoleAgent) = runUnitAction(onSuccess = { DetailActionState.Closed }) {
        consoleStore.closePane(hostId = agent.hostId, paneId = agent.paneId)
    }

    fun startInNewWorktree(agent: ConsoleAgent, proposedName: String) {
        val name = proposedName.trim()
        if (!AGENT_NAME.matches(name)) {
            mutableState.value = DetailActionState.Failed(
                "Agent names start with a lowercase letter and use up to 32 lowercase letters, numbers, underscores, or hyphens.",
            )
            return
        }
        runAgentAction(onSuccess = { started -> DetailActionState.WorktreeStarted(started.paneID) }) {
            consoleStore.startAgentInNewWorktree(
                hostId = agent.hostId,
                request = AgentLaunchRequest(
                    kind = agent.kind,
                    name = name,
                    workspaceID = agent.workspaceId,
                    cwd = agent.cwd,
                ),
                worktree = WorktreeSpec(),
            )
        }
    }

    fun clearResult() {
        mutableState.value = DetailActionState.Idle
    }

    private fun runUnitAction(
        onSuccess: () -> DetailActionState = { DetailActionState.Idle },
        action: suspend () -> Unit,
    ) {
        mutableState.value = DetailActionState.Running
        viewModelScope.launch {
            try {
                action()
                mutableState.value = onSuccess()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                mutableState.value = DetailActionState.Failed(actionErrorPresentation(error))
            }
        }
    }

    private fun runAgentAction(
        onSuccess: (dev.bybee.heeler.core.transport.Agent) -> DetailActionState,
        action: suspend () -> dev.bybee.heeler.core.transport.Agent,
    ) {
        mutableState.value = DetailActionState.Running
        viewModelScope.launch {
            try {
                mutableState.value = onSuccess(action())
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                mutableState.value = DetailActionState.Failed(actionErrorPresentation(error))
            }
        }
    }

    companion object {
        private val AGENT_NAME = Regex("[a-z][a-z0-9_-]{0,31}")

        fun factory(consoleStore: ConsoleStore): ViewModelProvider.Factory =
            object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>, extras: CreationExtras): T =
                    AgentDetailActionsStore(consoleStore) as T
            }
    }
}

private fun actionErrorPresentation(error: Throwable): String = when (error) {
    is TransportError -> error.connectionGuidance
    else -> error.message?.takeIf(String::isNotBlank) ?: "The Host did not accept the change. Try again."
}
