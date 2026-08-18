package dev.bybee.heeler.skills

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.bybee.heeler.core.transport.AgentSkill
import dev.bybee.heeler.core.transport.SkillListQuery
import dev.bybee.heeler.core.transport.SupportedAgentKind
import dev.bybee.heeler.core.transport.Transport
import dev.bybee.heeler.core.transport.TransportError
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** Cache identity: remote project skill discovery is only valid for this Host transport generation. */
data class SkillCacheKey(
    val hostId: String,
    val generation: Long,
    val kind: SupportedAgentKind,
    val projectRoot: String?,
)

sealed interface SkillsPhase {
    data object Idle : SkillsPhase
    data object Loading : SkillsPhase
    data object Loaded : SkillsPhase
    data class Failed(val message: String) : SkillsPhase
}

sealed interface SkillContentState {
    data object Hidden : SkillContentState
    data class Loading(val skill: AgentSkill) : SkillContentState
    data class Loaded(val skill: AgentSkill, val content: String) : SkillContentState
    data class Failed(val skill: AgentSkill, val message: String) : SkillContentState
}

data class SkillsPaneState(
    val phase: SkillsPhase = SkillsPhase.Idle,
    val request: SkillCacheKey? = null,
    val skills: List<AgentSkill> = emptyList(),
    val content: SkillContentState = SkillContentState.Hidden,
) {
    val projectSkills: List<AgentSkill> get() = skills.filter { it.scope == AgentSkill.Scope.PROJECT }
    val globalSkills: List<AgentSkill> get() = skills.filter { it.scope == AgentSkill.Scope.GLOBAL }
}

/**
 * Lazy skills probe. It accepts only narrow Host connection functions so the
 * Console connection manager remains the single SSH lifecycle owner.
 */
class SkillsPaneStore(
    private val transportForHost: suspend (String) -> Transport,
    private val generationForHost: (String) -> Long,
) : ViewModel() {
    private val _state = MutableStateFlow(SkillsPaneState())
    val state: StateFlow<SkillsPaneState> = _state.asStateFlow()

    private val listCache = mutableMapOf<SkillCacheKey, List<AgentSkill>>()
    private val contentCache = mutableMapOf<SkillContentCacheKey, String>()
    private var activeFetch: SkillCacheKey? = null

    /** Loads once for the current remote identity, or reuses the exact-generation cache. */
    fun loadIfNeeded(hostId: String, rawKind: String, projectRoot: String?) {
        val key = keyFor(hostId, rawKind, projectRoot) ?: return
        if (_state.value.request == key && _state.value.phase !is SkillsPhase.Idle) return
        load(key, forceRefresh = false)
    }

    /** Explicit pull-to-refresh that leaves the previous skills visible during the probe. */
    fun refresh(hostId: String, rawKind: String, projectRoot: String?) {
        val key = keyFor(hostId, rawKind, projectRoot) ?: return
        load(key, forceRefresh = true)
    }

    /** Makes remote text available only after the user asks to read it. */
    fun openContent(skill: AgentSkill) {
        val request = _state.value.request ?: return
        if (skill.path.isBlank()) {
            _state.value = _state.value.copy(
                content = SkillContentState.Failed(skill, "This skill has no readable source file."),
            )
            return
        }
        val key = SkillContentCacheKey(request, skill.path)
        contentCache[key]?.let {
            _state.value = _state.value.copy(content = SkillContentState.Loaded(skill, it))
            return
        }
        _state.value = _state.value.copy(content = SkillContentState.Loading(skill))
        viewModelScope.launch {
            try {
                val text = transportForHost(request.hostId).readSkillFile(skill.path)
                if (!isCurrent(request)) return@launch
                contentCache[key] = text
                _state.value = _state.value.copy(content = SkillContentState.Loaded(skill, text))
            } catch (failure: Exception) {
                if (isCurrent(request)) {
                    _state.value = _state.value.copy(
                        content = SkillContentState.Failed(skill, messageFor(failure, "Loading skill content failed.")),
                    )
                }
            }
        }
    }

    fun dismissContent() {
        _state.value = _state.value.copy(content = SkillContentState.Hidden)
    }

    /** Removes every stale entry for a Host. Safe to call from a connection-state observer. */
    fun invalidateForGeneration(hostId: String) {
        val currentGeneration = generationForHost(hostId)
        listCache.keys.removeAll { it.hostId == hostId && it.generation != currentGeneration }
        contentCache.keys.removeAll {
            it.listKey.hostId == hostId && it.listKey.generation != currentGeneration
        }
        val current = _state.value.request
        if (current?.hostId == hostId && current.generation != currentGeneration) {
            _state.value = SkillsPaneState()
        }
    }

    private fun keyFor(hostId: String, rawKind: String, projectRoot: String?): SkillCacheKey? {
        val kind = SupportedAgentKind.entries.firstOrNull { it.rawValue == rawKind }
        if (kind == null) {
            _state.value = SkillsPaneState(
                phase = SkillsPhase.Failed("Skills are unavailable for this Agent kind."),
            )
            return null
        }
        invalidateForGeneration(hostId)
        return SkillCacheKey(hostId, generationForHost(hostId), kind, projectRoot)
    }

    private fun load(key: SkillCacheKey, forceRefresh: Boolean) {
        if (activeFetch == key) return
        if (!forceRefresh) {
            listCache[key]?.let { cached ->
                _state.value = SkillsPaneState(SkillsPhase.Loaded, key, cached)
                return
            }
        }
        activeFetch = key
        val previousSkills = _state.value.takeIf { it.request == key }?.skills.orEmpty()
        _state.value = SkillsPaneState(SkillsPhase.Loading, key, previousSkills)
        viewModelScope.launch {
            try {
                val skills = transportForHost(key.hostId).listSkills(
                    SkillListQuery(key.kind, key.projectRoot),
                )
                if (!isCurrent(key)) return@launch
                listCache[key] = skills
                _state.value = SkillsPaneState(SkillsPhase.Loaded, key, skills)
            } catch (failure: Exception) {
                if (isCurrent(key)) {
                    _state.value = SkillsPaneState(
                        SkillsPhase.Failed(messageFor(failure, "Loading skills failed.")),
                        key,
                        previousSkills,
                    )
                }
            } finally {
                if (activeFetch == key) activeFetch = null
            }
        }
    }

    private fun isCurrent(key: SkillCacheKey): Boolean =
        _state.value.request == key && generationForHost(key.hostId) == key.generation

    private data class SkillContentCacheKey(val listKey: SkillCacheKey, val path: String)
}

private fun messageFor(failure: Exception, fallback: String): String = when (failure) {
    is TransportError.SshUnreachable -> "The Host is not connected."
    TransportError.TimedOut -> "The Host did not answer in time."
    else -> fallback
}

/**
 * Tools-keyboard Skills pane. A skill row inserts its command and trailing
 * space through [onInsert]; it never submits authored text to a terminal.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SkillsPane(
    store: SkillsPaneStore,
    hostId: String,
    kind: String,
    projectRoot: String?,
    onInsert: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val state by store.state.collectAsState()
    LaunchedEffect(hostId, kind, projectRoot) {
        store.loadIfNeeded(hostId, kind, projectRoot)
    }

    Column(modifier = modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        when (val phase = state.phase) {
            SkillsPhase.Idle -> Unit
            SkillsPhase.Loading -> {
                if (state.skills.isEmpty()) Text("Loading skills…", Modifier.padding(16.dp))
            }
            SkillsPhase.Loaded -> Unit
            is SkillsPhase.Failed -> {
                Text(phase.message, Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
                OutlinedButton(
                    onClick = { store.refresh(hostId, kind, projectRoot) },
                    modifier = Modifier.padding(horizontal = 16.dp),
                ) { Text("Retry") }
            }
        }

        if (state.skills.isEmpty() && state.phase == SkillsPhase.Loaded) {
            Text("No custom skills are available for this Agent.", Modifier.padding(16.dp))
        } else if (state.skills.isNotEmpty()) {
            LazyColumn(modifier = Modifier.weight(1f, fill = false)) {
                if (state.projectSkills.isNotEmpty()) {
                    item(key = "project-header") { SkillGroupHeader("Project") }
                    items(state.projectSkills, key = { "project-${it.id}" }) { skill ->
                        SkillRow(skill, onInsert = onInsert, onDetails = { store.openContent(skill) })
                    }
                }
                if (state.globalSkills.isNotEmpty()) {
                    item(key = "global-header") { SkillGroupHeader("Global") }
                    items(state.globalSkills, key = { "global-${it.id}" }) { skill ->
                        SkillRow(skill, onInsert = onInsert, onDetails = { store.openContent(skill) })
                    }
                }
            }
        }
    }

    when (val content = state.content) {
        SkillContentState.Hidden -> Unit
        is SkillContentState.Loading -> SkillContentSheet(content.skill, onDismiss = store::dismissContent) {
            Text("Loading skill content…", Modifier.padding(16.dp))
        }
        is SkillContentState.Loaded -> SkillContentSheet(content.skill, onDismiss = store::dismissContent) {
            LazyColumn(Modifier.padding(horizontal = 16.dp)) {
                item {
                    Text(
                        content.content,
                        fontFamily = FontFamily.Monospace,
                        modifier = Modifier.padding(bottom = 24.dp),
                    )
                }
            }
        }
        is SkillContentState.Failed -> SkillContentSheet(content.skill, onDismiss = store::dismissContent) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(content.message)
                OutlinedButton(onClick = { store.openContent(content.skill) }) { Text("Retry") }
            }
        }
    }
}

/** Typed convenience overload for callers which already resolved their Agent kind. */
@Composable
fun SkillsPane(
    store: SkillsPaneStore,
    hostId: String,
    kind: SupportedAgentKind,
    projectRoot: String?,
    onInsert: (String) -> Unit,
    modifier: Modifier = Modifier,
) = SkillsPane(store, hostId, kind.rawValue, projectRoot, onInsert, modifier)

@Composable
private fun SkillGroupHeader(title: String) {
    Text(
        title,
        fontWeight = FontWeight.SemiBold,
        style = MaterialTheme.typography.labelLarge,
        modifier = Modifier.padding(start = 16.dp, top = 12.dp, bottom = 4.dp),
    )
}

@Composable
private fun SkillRow(skill: AgentSkill, onInsert: (String) -> Unit, onDetails: () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Column(
                Modifier.weight(1f).clickable { onInsert(skill.insertionText) }.semantics {
                    contentDescription = "Insert ${skill.command} without sending"
                },
            ) {
                Text(skill.command, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold)
                skill.description?.let {
                    Text(it, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
            }
            TextButton(onClick = onDetails) { Text("Details") }
        }
        HorizontalDivider(Modifier.padding(top = 8.dp))
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SkillContentSheet(
    skill: AgentSkill,
    onDismiss: () -> Unit,
    content: @Composable () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState()) {
        Column(Modifier.fillMaxWidth()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(skill.command, style = MaterialTheme.typography.titleLarge)
                TextButton(onClick = onDismiss) { Text("Close") }
            }
            content()
        }
    }
}
