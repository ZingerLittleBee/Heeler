package dev.bybee.heeler.detail

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.ProcessLifecycleOwner
import androidx.lifecycle.viewmodel.compose.viewModel
import dev.bybee.heeler.HeelerApplication
import dev.bybee.heeler.snippets.SnippetsManagementScreen
import dev.bybee.heeler.console.ConsoleAgent
import dev.bybee.heeler.skills.SkillsPane
import dev.bybee.heeler.settings.TerminalAppearanceStore
import dev.bybee.heeler.skills.SkillsPaneStore
import dev.bybee.heeler.snippets.SnippetStore
import dev.bybee.heeler.staging.ComposerAttachmentPickerLaunchers
import dev.bybee.heeler.staging.ComposerStagingStatus
import dev.bybee.heeler.staging.ComposerStagingStore
import dev.bybee.heeler.terminal.TerminalCanvas

/**
 * Full Agent detail route. The NavHost owns navigation; this screen gets its
 * shared stores from the application container and never dials SSH directly.
 */
@Composable
fun AgentDetailScreen(hostId: String, paneId: String, onBack: () -> Unit) {
    val context = LocalContext.current
    val container = (context.applicationContext as HeelerApplication).container
    val connections = container.connectionManager
    val consoleStore = container.consoleStore
    val agents by consoleStore.agents.collectAsState()
    val agent = agents.firstOrNull { it.hostId == hostId && it.paneId == paneId }

    val attach: AgentAttachStore = viewModel(
        key = "attach:$hostId:$paneId",
        factory = AgentAttachStore.factory(hostId, paneId, connections),
    )
    val composer: AgentComposerStore = viewModel(
        key = "composer:$hostId:$paneId",
        factory = AgentComposerStore.factory(hostId, paneId, connections),
    )
    val actions: AgentDetailActionsStore = viewModel(
        key = "agent-actions:$hostId:$paneId",
        factory = AgentDetailActionsStore.factory(consoleStore),
    )
    val staging: ComposerStagingStore = viewModel(
        key = "staging:$hostId:$paneId",
        factory = detailViewModelFactory {
            ComposerStagingStore(
                context = context.applicationContext,
                transportProvider = { connections.transport(hostId) },
            )
        },
    )
    val appearance = container.terminalAppearanceStore
    val snippets = container.snippetStore
    val skills: SkillsPaneStore = viewModel(
        key = "skills:$hostId:$paneId",
        factory = detailViewModelFactory {
            SkillsPaneStore(connections::transport, connections::generation)
        },
    )

    DisposableEffect(staging) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) staging.onBackgrounded()
        }
        ProcessLifecycleOwner.get().lifecycle.addObserver(observer)
        onDispose { ProcessLifecycleOwner.get().lifecycle.removeObserver(observer) }
    }
    DisposableEffect(attach) {
        attach.rejoin()
        onDispose { attach.leave() }
    }
    LaunchedEffect(agent?.connectionGeneration) {
        agent?.let { attach.onConnectionGenerationChanged(it.connectionGeneration) }
    }
    LaunchedEffect(agent?.status) {
        agent?.let { composer.onAgentStatusChanged(it.status) }
    }

    if (agent == null) {
        MissingAgentDetail(onBack = onBack)
        return
    }

    AgentDetailLoaded(
        agent = agent,
        allAgents = agents,
        attach = attach,
        composer = composer,
        actions = actions,
        staging = staging,
        snippets = snippets,
        skills = skills,
        appearance = appearance,
        onBack = onBack,
        onSwitch = container.navigator::openAgent,
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AgentDetailLoaded(
    agent: ConsoleAgent,
    allAgents: List<ConsoleAgent>,
    attach: AgentAttachStore,
    composer: AgentComposerStore,
    appearance: TerminalAppearanceStore,
    actions: AgentDetailActionsStore,
    staging: ComposerStagingStore,
    snippets: SnippetStore,
    skills: SkillsPaneStore,
    onBack: () -> Unit,
    onSwitch: (String, String) -> Unit,
) {
    val attachState by attach.uiState.collectAsState()
    val actionState by actions.state.collectAsState()
    val appearanceState by appearance.state.collectAsState()
    val stagingState by staging.state.collectAsState()
    val context = LocalContext.current
    val uriHandler = LocalUriHandler.current
    var switcherExpanded by remember { mutableStateOf(false) }
    var actionsExpanded by remember { mutableStateOf(false) }
    var showingLinks by remember { mutableStateOf(false) }
    var renameOpen by remember { mutableStateOf(false) }
    var closeOpen by remember { mutableStateOf(false) }
    var worktreeOpen by remember { mutableStateOf(false) }
    var failedLink by remember { mutableStateOf<AttachLink?>(null) }
    var managingSnippets by remember { mutableStateOf(false) }
    LaunchedEffect(attachState.terminalHandle, appearanceState.theme) {
        appearance.applyToTerminal(attachState.terminalHandle)
        attach.refreshTerminalAppearance()
    }

    LaunchedEffect(actionState) {
        when (val result = actionState) {
            DetailActionState.Closed -> {
                attach.leave()
                actions.clearResult()
                onBack()
            }
            is DetailActionState.WorktreeStarted -> {
                actions.clearResult()
                onSwitch(agent.hostId, result.paneId)
            }
            else -> Unit
        }
    }

    Scaffold(
        topBar = {
            CenterAlignedTopAppBar(
                title = {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(agent.displayName, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(
                            agent.hostName,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                },
                navigationIcon = { TextButton(onClick = { attach.leave(); onBack() }) { Text("Back") } },
                actions = {
                    if (attachState.links.isNotEmpty()) {
                        TextButton(onClick = { showingLinks = true }) { Text("Links ${attachState.links.size}") }
                    }
                    Box {
                        TextButton(onClick = { switcherExpanded = true }) { Text("Agents") }
                        AgentSwitcherMenu(
                            expanded = switcherExpanded,
                            agents = allAgents,
                            selected = agent,
                            onDismiss = { switcherExpanded = false },
                            onSelect = { selected ->
                                switcherExpanded = false
                                if (selected.id != agent.id) onSwitch(selected.hostId, selected.paneId)
                            },
                        )
                    }
                    Box {
                        TextButton(onClick = { actionsExpanded = true }) { Text("More") }
                        DropdownMenu(expanded = actionsExpanded, onDismissRequest = { actionsExpanded = false }) {
                            DropdownMenuItem(
                                text = { Text("Rename Agent") },
                                onClick = { actionsExpanded = false; renameOpen = true },
                            )
                            DropdownMenuItem(
                                text = { Text("New Worktree Agent") },
                                onClick = { actionsExpanded = false; worktreeOpen = true },
                            )
                            DropdownMenuItem(
                                text = { Text("Close Agent") },
                                onClick = { actionsExpanded = false; closeOpen = true },
                            )
                        }
                    }
                },
                colors = TopAppBarDefaults.centerAlignedTopAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surface,
                ),
            )
        },
    ) { padding ->
        ComposerAttachmentPickerLaunchers(store = staging, onInserted = composer::insertIntoDraft) { pickPhoto, pickFile ->
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .background(MaterialTheme.colorScheme.surface),
            ) {
                Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
                    TerminalCanvas(
                        snapshot = attachState.snapshot,
                        terminalHandle = attachState.terminalHandle,
                        modifier = Modifier.fillMaxSize(),
                        onResize = { cols, rows, cellWidth, cellHeight, _, _ ->
                            attach.onTerminalResize(cols, rows, cellWidth, cellHeight)
                        },
                        onScroll = attach::scrollTerminal,
                        onTap = {},
                        fontSizeSp = appearanceState.fontSizeSp,
                        onFontSizeChange = appearance::setFontSizeSp,
                    )
                    AttachStatusOverlay(attachState.status, attach::reattach, Modifier.align(Alignment.Center))
                }
                ComposerStagingStatus(
                    state = stagingState,
                    onCancel = staging::cancel,
                    onRetry = staging::retry,
                    onDismiss = staging::dismiss,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp),
                )
                AgentDetailComposer(
                    store = composer,
                    attach = attach,
                    snippets = snippets,
                    skills = skills,
                    agent = agent,
                    onPickPhoto = pickPhoto,
                    onPickFile = pickFile,
                    onManageSnippets = { managingSnippets = true },
                )
            }
        }
    }
    if (managingSnippets) {
        ModalBottomSheet(onDismissRequest = { managingSnippets = false }) {
            SnippetsManagementScreen(
                store = snippets,
                onClose = { managingSnippets = false },
                modifier = Modifier.fillMaxSize(),
            )
        }
    }

    if (showingLinks) {
        AttachLinksSheet(
            links = attachState.links,
            onDismiss = { showingLinks = false },
            onOpen = { link ->
                runCatching { uriHandler.openUri(link.target) }.onFailure { failedLink = link }
            },
            onCopy = { link -> copyLink(context, link.target) },
        )
    }
    failedLink?.let { link ->
        AlertDialog(
            onDismissRequest = { failedLink = null },
            title = { Text("Couldn't open link") },
            text = { Text("The link to ${link.host.ifBlank { "this Host" }} could not be opened. You can copy it instead.") },
            confirmButton = {
                TextButton(onClick = { copyLink(context, link.target); failedLink = null }) { Text("Copy link") }
            },
            dismissButton = { TextButton(onClick = { failedLink = null }) { Text("Cancel") } },
        )
    }
    if (renameOpen) {
        AgentNameDialog(
            title = "Rename Agent",
            initialName = agent.name.orEmpty(),
            confirmLabel = "Rename",
            busy = actionState is DetailActionState.Running,
            onDismiss = { renameOpen = false },
            onConfirm = { actions.rename(agent, it); renameOpen = false },
        )
    }
    if (worktreeOpen) {
        AgentNameDialog(
            title = "New Worktree Agent",
            initialName = worktreeNameFor(agent),
            confirmLabel = "Create",
            busy = actionState is DetailActionState.Running,
            onDismiss = { worktreeOpen = false },
            onConfirm = { actions.startInNewWorktree(agent, it); worktreeOpen = false },
        )
    }
    if (closeOpen) {
        AlertDialog(
            onDismissRequest = { closeOpen = false },
            title = { Text("Close ${agent.displayName}?") },
            text = { Text("This closes the pane on the Host and removes the Agent everywhere. This cannot be undone.") },
            confirmButton = {
                Button(
                    onClick = { actions.close(agent); closeOpen = false },
                    enabled = actionState !is DetailActionState.Running,
                ) { Text("Close Agent") }
            },
            dismissButton = { TextButton(onClick = { closeOpen = false }) { Text("Cancel") } },
        )
    }
    (actionState as? DetailActionState.Failed)?.let { failure ->
        AlertDialog(
            onDismissRequest = actions::clearResult,
            title = { Text("Couldn't complete change") },
            text = { Text(failure.message) },
            confirmButton = { TextButton(onClick = actions::clearResult) { Text("OK") } },
        )
    }
}

@Composable
private fun MissingAgentDetail(onBack: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("This Agent is no longer available.", style = MaterialTheme.typography.titleMedium)
        Spacer(Modifier.height(12.dp))
        Text("It may have been closed on the Host.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(20.dp))
        Button(onClick = onBack) { Text("Back to Console") }
    }
}

@Composable
private fun AttachStatusOverlay(status: AttachStatus, onReattach: () -> Unit, modifier: Modifier = Modifier) {
    when (status) {
        AttachStatus.AwaitingSize, AttachStatus.Live -> Unit
        AttachStatus.Connecting -> Text("Connecting…", modifier = modifier, style = MaterialTheme.typography.titleMedium)
        AttachStatus.Ended -> Column(modifier = modifier, horizontalAlignment = Alignment.CenterHorizontally) {
            Text("Attach ended", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(8.dp))
            Button(onClick = onReattach) { Text("Reattach") }
        }
        is AttachStatus.Failed -> Column(modifier = modifier, horizontalAlignment = Alignment.CenterHorizontally) {
            Text(status.message, modifier = Modifier.padding(horizontal = 24.dp))
            Spacer(Modifier.height(8.dp))
            Button(onClick = onReattach) { Text("Retry Attach") }
        }
    }
}

@Composable
private fun AgentSwitcherMenu(
    expanded: Boolean,
    agents: List<ConsoleAgent>,
    selected: ConsoleAgent,
    onDismiss: () -> Unit,
    onSelect: (ConsoleAgent) -> Unit,
) {
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        agents.forEach { candidate ->
            DropdownMenuItem(
                text = {
                    Column {
                        Text(candidate.switcherLabel, fontWeight = if (candidate.id == selected.id) FontWeight.Bold else FontWeight.Normal)
                        Text(
                            "${candidate.hostName} · ${candidate.status.rawValue}",
                            style = MaterialTheme.typography.labelSmall,
                        )
                    }
                },
                onClick = { onSelect(candidate) },
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AttachLinksSheet(
    links: List<AttachLink>,
    onDismiss: () -> Unit,
    onOpen: (AttachLink) -> Unit,
    onCopy: (AttachLink) -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Text(
            "Attach Links",
            style = MaterialTheme.typography.titleLarge,
            modifier = Modifier.padding(horizontal = 24.dp, vertical = 12.dp),
        )
        LazyColumn(modifier = Modifier.fillMaxWidth().weight(1f, fill = false)) {
            items(links, key = AttachLink::target) { link ->
                Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 12.dp)) {
                    Text(link.host, style = MaterialTheme.typography.labelMedium)
                    Text(link.target, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TextButton(onClick = { onOpen(link) }) { Text("Open") }
                        TextButton(onClick = { onCopy(link) }) { Text("Copy") }
                    }
                }
                HorizontalDivider()
            }
        }
        Spacer(Modifier.height(16.dp))
    }
}

@Composable
private fun AgentNameDialog(
    title: String,
    initialName: String,
    confirmLabel: String,
    busy: Boolean,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    var name by remember(initialName) { mutableStateOf(initialName) }
    AlertDialog(
        onDismissRequest = { if (!busy) onDismiss() },
        title = { Text(title) },
        text = {
            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text("Agent name") },
                singleLine = true,
            )
        },
        confirmButton = {
            Button(
                onClick = { onConfirm(name) },
                enabled = name.isNotBlank() && !busy,
            ) { Text(confirmLabel) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, enabled = !busy) { Text("Cancel") }
        },
    )
}

private fun copyLink(context: Context, target: String) {
    context.getSystemService(ClipboardManager::class.java)
        .setPrimaryClip(ClipData.newPlainText("Attach Link", target))
}
private fun worktreeNameFor(agent: ConsoleAgent): String {
    val source = agent.name ?: agent.kind
    val normalized = source.lowercase()
        .replace(Regex("[^a-z0-9_-]"), "-")
        .trim('-')
        .ifBlank { "agent" }
    val startsWithLetter = if (normalized.first() in 'a'..'z') normalized else "agent-$normalized"
    return "${startsWithLetter.take(22)}-worktree".take(32)
}

private fun <T : ViewModel> detailViewModelFactory(create: () -> T): ViewModelProvider.Factory =
    object : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <R : ViewModel> create(modelClass: Class<R>): R = create() as R
    }
