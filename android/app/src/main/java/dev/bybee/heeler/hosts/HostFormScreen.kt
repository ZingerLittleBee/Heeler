package dev.bybee.heeler.hosts

import android.content.Context
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.compose.viewModel
import dev.bybee.heeler.data.Host
import dev.bybee.heeler.data.HostStore

/** Add/edit Host screen used by `host/new` and `host/{hostId}` edit actions. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HostFormScreen(
    hostStore: HostStore,
    editing: Host?,
    onSaved: (Host) -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val viewModel: HostFormViewModel = viewModel(
        key = "host-form-${editing?.id ?: "new"}",
        factory = remember(context.applicationContext, hostStore, editing) {
            HostFormViewModelFactory(context.applicationContext, hostStore, editing)
        },
    )
    val state by viewModel.state.collectAsState()
    var replacingDeviceKey by remember { mutableStateOf(false) }

    LaunchedEffect(state.savedHost?.id) {
        state.savedHost?.let {
            viewModel.consumeSavedHost()
            onSaved(it)
        }
    }
    if (replacingDeviceKey) {
        AlertDialog(
            onDismissRequest = { replacingDeviceKey = false },
            title = { Text("Replace Device Key?") },
            text = {
                Text(
                    "Every Host using Device Key authentication will reject the replacement until " +
                        "its new public key is installed in ~/.ssh/authorized_keys.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    replacingDeviceKey = false
                    viewModel.replaceDeviceKey()
                }) { Text("Replace") }
            },
            dismissButton = { TextButton(onClick = { replacingDeviceKey = false }) { Text("Cancel") } },
        )
    }

    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text(if (editing == null) "Add Host" else "Edit Host") },
                navigationIcon = { TextButton(onClick = onCancel) { Text("Cancel") } },
                actions = {
                    TextButton(
                        onClick = viewModel::save,
                        enabled = state.canSave(editing) && !state.saving,
                    ) { Text(if (state.saving) "Saving…" else "Save") }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            SectionTitle("Host")
            OutlinedTextField(
                value = state.displayName,
                onValueChange = { value -> viewModel.update { it.copy(displayName = value) } },
                label = { Text("Name (optional)") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
            )
            OutlinedTextField(
                value = state.address,
                onValueChange = { value -> viewModel.update { it.copy(address = value) } },
                label = { Text("Address") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = state.port,
                    onValueChange = { value -> viewModel.update { it.copy(port = value) } },
                    label = { Text("Port") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.weight(0.35f),
                    singleLine = true,
                )
                OutlinedTextField(
                    value = state.username,
                    onValueChange = { value -> viewModel.update { it.copy(username = value) } },
                    label = { Text("User") },
                    modifier = Modifier.weight(0.65f),
                    singleLine = true,
                )
            }

            HorizontalDivider()
            SectionTitle("Authentication")
            AuthenticationChoice(
                title = "Device Key",
                selected = state.authentication == HostAuthenticationMode.DeviceKey,
                onClick = { viewModel.update { it.copy(authentication = HostAuthenticationMode.DeviceKey) } },
            )
            AuthenticationChoice(
                title = "Password",
                selected = state.authentication == HostAuthenticationMode.Password,
                onClick = { viewModel.update { it.copy(authentication = HostAuthenticationMode.Password) } },
            )
            when (state.authentication) {
                HostAuthenticationMode.DeviceKey -> DeviceKeyDetails(
                    state = state,
                    onRetry = viewModel::loadDeviceKey,
                    onReplace = { replacingDeviceKey = true },
                )
                HostAuthenticationMode.Password -> OutlinedTextField(
                    value = state.password,
                    onValueChange = { value -> viewModel.update { it.copy(password = value) } },
                    label = { Text(if (editing?.auth is dev.bybee.heeler.data.HostAuth.Password) "Password (blank keeps current)" else "Password") },
                    visualTransformation = PasswordVisualTransformation(),
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                )
            }

            HorizontalDivider()
            SectionTitle("herdr Session")
            OutlinedTextField(
                value = state.sessionName,
                onValueChange = { value -> viewModel.update { it.copy(sessionName = value) } },
                label = { Text("Session name") },
                supportingText = { Text("Leave blank for the default herdr session.") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
            )

            HorizontalDivider()
            SectionTitle("Jump Host")
            OutlinedTextField(
                value = state.jumpAddress,
                onValueChange = { value -> viewModel.update { it.copy(jumpAddress = value) } },
                label = { Text("Jump Host address (optional)") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
            )
            if (state.usesJumpHost) {
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    OutlinedTextField(
                        value = state.jumpPort,
                        onValueChange = { value -> viewModel.update { it.copy(jumpPort = value) } },
                        label = { Text("Jump Host port") },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        modifier = Modifier.weight(0.35f),
                        singleLine = true,
                    )
                    OutlinedTextField(
                        value = state.jumpUsername,
                        onValueChange = { value -> viewModel.update { it.copy(jumpUsername = value) } },
                        label = { Text("Jump Host user (same as Host if blank)") },
                        modifier = Modifier.weight(0.65f),
                        singleLine = true,
                    )
                }
                Text(
                    "The Host address and port are resolved from the Jump Host, normally through a " +
                        "loopback-only reverse tunnel. Both machines must accept this authentication " +
                        "method, and each host key is confirmed independently on first connect.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            } else {
                Text(
                    "Leave blank to connect to the Host directly.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            state.saveError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        }
    }
}

@Composable
private fun DeviceKeyDetails(
    state: HostFormUiState,
    onRetry: () -> Unit,
    onReplace: () -> Unit,
) {
    val clipboard = LocalClipboardManager.current
    state.authorizedKeyLine?.let { line ->
        Text("Add this public line to ~/.ssh/authorized_keys. The private key never leaves this device.")
        Text(line, style = MaterialTheme.typography.bodySmall)
        Button(onClick = { clipboard.setText(AnnotatedString(line)) }) { Text("Copy authorized_keys line") }
    } ?: when (state.deviceKeyError) {
        DeviceKeyPresentation.Corrupt -> {
            Text("The Device Key is corrupted.", color = MaterialTheme.colorScheme.error)
            Button(onClick = onReplace) { Text("Replace Device Key") }
        }
        DeviceKeyPresentation.Unavailable -> {
            Text("The Device Key is unavailable.", color = MaterialTheme.colorScheme.error)
            TextButton(onClick = onRetry) { Text("Try again") }
        }
        null -> Text("Loading Device Key…")
    }
}

@Composable
private fun AuthenticationChoice(title: String, selected: Boolean, onClick: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected, onClick = onClick)
        Spacer(Modifier.width(8.dp))
        Text(title)
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(text, style = MaterialTheme.typography.titleMedium)
}

private class HostFormViewModelFactory(
    private val context: Context,
    private val store: HostStore,
    private val editing: Host?,
) : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T = HostFormViewModel(context, store, editing) as T
}
