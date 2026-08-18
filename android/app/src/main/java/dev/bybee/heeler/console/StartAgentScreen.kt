package dev.bybee.heeler.console

import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import dev.bybee.heeler.core.transport.AgentLaunchRequest
import dev.bybee.heeler.core.transport.SupportedAgentKind
import dev.bybee.heeler.core.transport.TransportError
import dev.bybee.heeler.core.transport.WorktreeSpec
import dev.bybee.heeler.core.transport.connectionGuidance
import dev.bybee.heeler.data.Host
import dev.bybee.heeler.data.HostStore
import kotlinx.coroutines.launch

/** Starts a supported Agent in an existing workspace or a fresh Worktree. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StartAgentScreen(
    consoleStore: ConsoleStore,
    hostStore: HostStore,
    initialHostId: String? = null,
    onStarted: (hostId: String, paneId: String) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val hosts by hostStore.hosts.collectAsState()
    val workspacesByHost by consoleStore.workspacesByHost.collectAsState()
    var selectedHostId by remember { mutableStateOf(initialHostId) }
    var kinds by remember { mutableStateOf<List<SupportedAgentKind>>(emptyList()) }
    var selectedKind by remember { mutableStateOf<SupportedAgentKind?>(null) }
    var selectedWorkspaceId by remember { mutableStateOf<String?>(null) }
    var agentName by remember { mutableStateOf("") }
    var arguments by remember { mutableStateOf("") }
    var createWorktree by remember { mutableStateOf(false) }
    var branch by remember { mutableStateOf("") }
    var isLoadingKinds by remember { mutableStateOf(false) }
    var isStarting by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    LaunchedEffect(hosts, initialHostId) {
        if (selectedHostId !in hosts.map(Host::id)) {
            selectedHostId = initialHostId?.takeIf { candidate -> hosts.any { it.id == candidate } }
                ?: hosts.firstOrNull()?.id
        }
    }
    LaunchedEffect(selectedHostId) {
        selectedKind = null
        selectedWorkspaceId = null
        kinds = emptyList()
        errorMessage = null
        val hostId = selectedHostId ?: return@LaunchedEffect
        isLoadingKinds = true
        try {
            kinds = consoleStore.availableAgentKinds(hostId)
            selectedKind = kinds.firstOrNull()
        } catch (failure: Throwable) {
            errorMessage = failure.userMessage()
        } finally {
            isLoadingKinds = false
        }
    }

    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text("New Agent") },
                navigationIcon = {
                    TextButton(onClick = onBack) {
                        androidx.compose.material3.Icon(
                            Icons.AutoMirrored.Outlined.ArrowBack,
                            contentDescription = "Back",
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surface,
                ),
            )
        },
    ) { contentPadding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(contentPadding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            item {
                FormSection("Host") {
                    ChoiceRow(
                        choices = hosts,
                        selected = selectedHostId,
                        label = Host::name,
                        id = Host::id,
                        onSelect = { selectedHostId = it },
                    )
                }
            }
            item {
                FormSection("Agent") {
                    when {
                        isLoadingKinds -> Row(verticalAlignment = Alignment.CenterVertically) {
                            CircularProgressIndicator(modifier = Modifier.height(20.dp))
                            Spacer(Modifier.width(12.dp))
                            Text("Checking supported Agents…")
                        }
                        kinds.isEmpty() -> Text(
                            "No supported Agent executable was found on this Host.",
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        else -> ChoiceRow(
                            choices = kinds,
                            selected = selectedKind?.rawValue,
                            label = SupportedAgentKind::displayName,
                            id = SupportedAgentKind::rawValue,
                            onSelect = { raw -> selectedKind = kinds.firstOrNull { it.rawValue == raw } },
                        )
                    }
                }
            }
            item {
                FormSection("Workspace") {
                    val workspaces = selectedHostId?.let(workspacesByHost::get).orEmpty()
                    if (workspaces.isEmpty()) {
                        Text(
                            "The Host has not reported a workspace yet. Pull to refresh the Console after it connects.",
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    } else {
                        ChoiceRow(
                            choices = workspaces,
                            selected = selectedWorkspaceId,
                            label = ConsoleWorkspace::label,
                            id = ConsoleWorkspace::id,
                            onSelect = { selectedWorkspaceId = it },
                        )
                    }
                }
            }
            item {
                FormSection("Launch") {
                    OutlinedTextField(
                        value = agentName,
                        onValueChange = { agentName = it.lowercase() },
                        label = { Text("Agent name") },
                        supportingText = { Text("Lowercase letters, digits, _ and -; starts with a letter.") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(12.dp))
                    OutlinedTextField(
                        value = arguments,
                        onValueChange = { arguments = it },
                        label = { Text("Arguments") },
                        supportingText = { Text("Space-separated arguments passed to the Agent.") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Text),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(12.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text("New Worktree", style = MaterialTheme.typography.titleSmall)
                            Text(
                                "Start from a clean git checkout rather than the selected workspace.",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        Switch(checked = createWorktree, onCheckedChange = { createWorktree = it })
                    }
                    if (createWorktree) {
                        Spacer(Modifier.height(12.dp))
                        OutlinedTextField(
                            value = branch,
                            onValueChange = { branch = it },
                            label = { Text("Worktree branch (optional)") },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }
            errorMessage?.let { message ->
                item {
                    Text(message, color = MaterialTheme.colorScheme.error)
                }
            }
            item {
                Button(
                    enabled = !isStarting && selectedHostId != null && selectedKind != null && validAgentName(agentName),
                    onClick = {
                        val hostId = selectedHostId ?: return@Button
                        val kind = selectedKind ?: return@Button
                        val normalizedName = agentName.trim()
                        if (!validAgentName(normalizedName)) {
                            errorMessage = "Enter a valid Agent name before starting."
                            return@Button
                        }
                        scope.launch {
                            isStarting = true
                            errorMessage = null
                            try {
                                val request = AgentLaunchRequest(
                                    kind = kind.rawValue,
                                    name = normalizedName,
                                    arguments = arguments.trim().split(Regex("\\s+")).filter(String::isNotBlank),
                                    workspaceID = selectedWorkspaceId,
                                )
                                val agent = if (createWorktree) {
                                    consoleStore.startAgentInNewWorktree(
                                        hostId,
                                        request,
                                        WorktreeSpec(branch = branch.trim().ifBlank { null }),
                                    )
                                } else {
                                    consoleStore.startAgent(hostId, request)
                                }
                                onStarted(hostId, agent.paneID)
                            } catch (failure: Throwable) {
                                errorMessage = failure.userMessage()
                            } finally {
                                isStarting = false
                            }
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    if (isStarting) {
                        CircularProgressIndicator(
                            modifier = Modifier.height(18.dp),
                            color = MaterialTheme.colorScheme.onPrimary,
                        )
                        Spacer(Modifier.width(12.dp))
                    }
                    Text(if (isStarting) "Starting…" else "Start Agent")
                }
            }
        }
    }
}

@Composable
private fun FormSection(title: String, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, style = MaterialTheme.typography.titleMedium)
        content()
    }
}

@Composable
private fun <T> ChoiceRow(
    choices: List<T>,
    selected: String?,
    label: (T) -> String,
    id: (T) -> String,
    onSelect: (String) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(androidx.compose.foundation.rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        choices.forEach { choice ->
            val choiceId = id(choice)
            FilterChip(
                selected = choiceId == selected,
                onClick = { onSelect(choiceId) },
                label = { Text(label(choice)) },
            )
        }
    }
}

private fun validAgentName(value: String): Boolean =
    value.matches(Regex("^[a-z][a-z0-9_-]{0,31}$"))

private fun Throwable.userMessage(): String = when (this) {
    is TransportError -> connectionGuidance
    else -> "Could not start this Agent. Check the Host connection and try again."
}
