package dev.bybee.heeler.hosts

import android.content.Context
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
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
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.compose.viewModel
import dev.bybee.heeler.connection.HostConnectionManager
import dev.bybee.heeler.connection.HostConnectionState
import dev.bybee.heeler.core.transport.connectionGuidance
import dev.bybee.heeler.data.Host
import dev.bybee.heeler.data.HostAuth
import dev.bybee.heeler.data.HostStore
import dev.bybee.heeler.notifications.NotificationRegistrationSection
import dev.bybee.heeler.notifications.NotificationRegistrationStore
import kotlinx.coroutines.launch

/** Host preflight/detail for `host/{hostId}`, including trust, session selection, and notifications. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HostDetailScreen(
    hostId: String,
    hostStore: HostStore,
    connections: HostConnectionManager,
    notificationStore: NotificationRegistrationStore?,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val hosts by hostStore.hosts.collectAsState()
    val host = hosts.firstOrNull { it.id == hostId }
    if (host == null) {
        Scaffold(modifier = modifier, topBar = { TopAppBar(title = { Text("Host") }) }) { padding ->
            Column(Modifier.fillMaxSize().padding(padding).padding(24.dp)) {
                Text("This Host no longer exists.")
                TextButton(onClick = onBack) { Text("Back") }
            }
        }
        return
    }

    var editing by remember(host.id) { mutableStateOf(false) }
    if (editing) {
        HostFormScreen(
            hostStore = hostStore,
            editing = host,
            onSaved = { editing = false },
            onCancel = { editing = false },
            modifier = modifier,
        )
        return
    }

    val context = androidx.compose.ui.platform.LocalContext.current
    val viewModel: HostOnboardingViewModel = viewModel(
        key = "host-onboarding-${host.id}",
        factory = remember(context.applicationContext, hostStore, host) {
            HostOnboardingViewModelFactory(context.applicationContext, hostStore, host)
        },
    )
    val state by viewModel.state.collectAsState()
    val connectionState by connections.state(host.id).collectAsState()
    val scope = rememberCoroutineScope()
    var confirmingReplacement by remember { mutableStateOf(false) }

    LaunchedEffect(host) { viewModel.updateHost(host) }
    LaunchedEffect(host.id) { viewModel.runChecks() }

    state.pendingFingerprint?.let { candidate ->
        AlertDialog(
            onDismissRequest = { },
            title = { Text("Trust this Host?") },
            text = {
                Text(
                    "First connection to ${candidate.host}:${candidate.port}.\n\n" +
                        "Key fingerprint:\n${candidate.fingerprint.displayString}\n\n" +
                        "Verify it with the Host owner before trusting it. This request expires in 60 seconds.",
                )
            },
            confirmButton = {
                TextButton(onClick = { viewModel.confirmFingerprint(true) }) { Text("Trust") }
            },
            dismissButton = {
                TextButton(onClick = { viewModel.confirmFingerprint(false) }) { Text("Don't trust") }
            },
        )
    }
    if (confirmingReplacement) {
        val replacement = state.pendingReplacement
        AlertDialog(
            onDismissRequest = { confirmingReplacement = false },
            title = { Text("Trust new Host key?") },
            text = {
                Text(
                    replacement?.let {
                        "Trusted:\n${it.known.displayString}\n\nPresented:\n${it.presented.displayString}\n\n" +
                            "A changed key can indicate a reinstalled Host or an attack."
                    }.orEmpty(),
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmingReplacement = false
                    viewModel.trustReplacement()
                }) { Text("Trust new key") }
            },
            dismissButton = { TextButton(onClick = { confirmingReplacement = false }) { Text("Cancel") } },
        )
    }

    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text(host.name) },
                navigationIcon = { TextButton(onClick = onBack) { Text("Back") } },
                actions = { TextButton(onClick = { editing = true }) { Text("Edit") } },
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            item {
                DetailCard(host)
            }
            item {
                ConnectionCard(
                    connectionState = connectionState,
                    onReconnect = { scope.launch { connections.reconnect(host.id) } },
                )
            }
            item {
                PreflightCard(state)
            }
            if (state.availableSessions.isNotEmpty() || state.sessionDiscoveryError != null) {
                item {
                    SessionsCard(
                        selectedName = host.sessionName,
                        sessions = state.availableSessions,
                        error = state.sessionDiscoveryError,
                        onSelect = viewModel::selectSession,
                    )
                }
            }
            item {
                Button(
                    onClick = viewModel::runChecks,
                    enabled = state.phase != PreflightPhase.Running,
                    modifier = Modifier.fillMaxWidth(),
                ) { Text(if (state.phase == PreflightPhase.Running) "Running checks…" else "Run checks again") }
            }
            if (state.pendingReplacement != null) {
                item {
                    OutlinedButton(
                        onClick = { confirmingReplacement = true },
                        modifier = Modifier.fillMaxWidth(),
                    ) { Text("Trust new Host key") }
                    Text(
                        "Only continue after verifying the new fingerprint with the Host owner.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            notificationStore?.let { store ->
                item {
                    HorizontalDivider()
                    NotificationRegistrationSection(
                        hostId = host.id,
                        hostName = host.displayName ?: host.address,
                        store = store,
                        modifier = Modifier.padding(top = 10.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun DetailCard(host: Host) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("Host", style = MaterialTheme.typography.titleMedium)
            Text("${host.username}@${host.address}:${host.port}")
            Text("Session: ${host.sessionName ?: "default"}")
            Text("Authentication: ${if (host.auth is HostAuth.DeviceKey) "Device Key" else "Password"}")
            host.jumpHost?.let { jump -> Text("Jump Host: ${jump.username}@${jump.address}:${jump.port}") }
        }
    }
}

@Composable
private fun ConnectionCard(
    connectionState: HostConnectionState,
    onReconnect: () -> Unit,
) {
    val guidance = when (connectionState) {
        is HostConnectionState.Reconnecting -> connectionState.error.connectionGuidance
        is HostConnectionState.Failed -> connectionState.error.connectionGuidance
        else -> null
    }
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Connection", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                AssistChip(onClick = {}, label = { Text(connectionLabel(connectionState)) })
            }
            guidance?.let {
                Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
            }
            Button(
                onClick = onReconnect,
                enabled = connectionState !is HostConnectionState.Connecting &&
                    connectionState !is HostConnectionState.Reconnecting,
            ) { Text("Reconnect") }
        }
    }
}

@Composable
private fun PreflightCard(state: HostOnboardingUiState) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Preflight", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                if (state.phase == PreflightPhase.Running) {
                    Text("Checking…", style = MaterialTheme.typography.bodySmall)
                }
            }
            PreflightCheck.entries.forEach { check ->
                val status = state.report?.status(check)
                Row(verticalAlignment = Alignment.Top) {
                    Text(preflightGlyph(status), modifier = Modifier.width(24.dp))
                    Column(Modifier.weight(1f)) {
                        Text(check.title)
                        if (status is PreflightCheckStatus.Failed) {
                            Text(
                                status.hint,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.error,
                            )
                        }
                    }
                }
            }
            state.serverVersion?.let { version ->
                val protocol = state.protocolVersion ?: return@let
                Text(
                    if (state.protocolIsNewerThanApp) {
                        "herdr $version · protocol $protocol — newer than this app was built against."
                    } else {
                        "herdr $version · protocol $protocol"
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun SessionsCard(
    selectedName: String?,
    sessions: List<dev.bybee.heeler.core.transport.HerdrSession>,
    error: String?,
    onSelect: (dev.bybee.heeler.core.transport.HerdrSession) -> Unit,
) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Available sessions", style = MaterialTheme.typography.titleMedium)
            sessions.forEach { session ->
                val selected = if (session.isDefault) selectedName == null else selectedName == session.name
                TextButton(
                    onClick = { onSelect(session) },
                    enabled = !selected && (session.isDefault || session.isRunning),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Column(Modifier.fillMaxWidth()) {
                        Text(session.name)
                        Text(
                            when {
                                selected -> "Selected"
                                session.isRunning -> "Running"
                                else -> "Stopped — start it on the Host before selecting"
                            },
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
            }
            error?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error) }
        }
    }
}

private fun connectionLabel(state: HostConnectionState): String = when (state) {
    HostConnectionState.Connecting -> "Connecting…"
    is HostConnectionState.Connected -> state.latencyMillis?.let { "Connected · ${it} ms" } ?: "Connected"
    is HostConnectionState.Reconnecting -> "Reconnecting…"
    is HostConnectionState.Failed -> "Unavailable"
    HostConnectionState.Suspended -> "Suspended"
}

private fun preflightGlyph(status: PreflightCheckStatus?): String = when (status) {
    PreflightCheckStatus.Passed -> "✓"
    is PreflightCheckStatus.Failed -> "!"
    PreflightCheckStatus.Blocked -> "–"
    null -> "·"
}

private class HostOnboardingViewModelFactory(
    private val context: Context,
    private val hostStore: HostStore,
    private val host: Host,
) : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T =
        HostOnboardingViewModel(context, hostStore, host) as T
}
