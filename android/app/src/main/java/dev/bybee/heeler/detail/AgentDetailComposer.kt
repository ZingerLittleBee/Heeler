package dev.bybee.heeler.detail

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import dev.bybee.heeler.console.ConsoleAgent
import dev.bybee.heeler.skills.SkillsPane
import dev.bybee.heeler.skills.SkillsPaneStore
import dev.bybee.heeler.snippets.SnippetStore

private enum class ComposerKeyboard { SYSTEM, TOOLS }
private enum class ToolsTab { CONTROLS, SNIPPETS, SKILLS }

/** Native draft field plus the mutually exclusive system/tools keyboard modes. */
@Composable
fun AgentDetailComposer(
    store: AgentComposerStore,
    attach: AgentAttachStore,
    snippets: SnippetStore,
    skills: SkillsPaneStore,
    agent: ConsoleAgent,
    onPickPhoto: () -> Unit,
    onPickFile: () -> Unit,
    onManageSnippets: () -> Unit,
) {
    val state by store.uiState.collectAsState()
    val clipboard = LocalClipboardManager.current
    val focusManager = LocalFocusManager.current
    val focusRequester = remember { FocusRequester() }
    var keyboard by remember { mutableStateOf(ComposerKeyboard.SYSTEM) }
    var selectedToolsTab by remember { mutableStateOf(ToolsTab.CONTROLS) }
    var pendingPaste by remember { mutableStateOf<String?>(null) }
    val fieldValue = TextFieldValue(
        text = state.draft,
        selection = TextRange(state.selectionStart, state.selectionEnd),
    )

    Column(Modifier.fillMaxWidth()) {
        HorizontalDivider()
        state.messages.takeLast(2).forEach { message ->
            ComposerMessageStatus(
                message = message,
                onRetry = { store.retry(message.id) },
                onRestore = { store.restoreFailedToDraft(message.id) },
            )
        }
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            OutlinedTextField(
                value = fieldValue,
                onValueChange = { value -> store.setDraft(value.text, value.selection.start, value.selection.end) },
                modifier = Modifier.weight(1f).focusRequester(focusRequester),
                label = { Text("Composer") },
                placeholder = { Text("Message the Agent") },
                maxLines = 4,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Text, imeAction = ImeAction.Send),
                keyboardActions = androidx.compose.foundation.text.KeyboardActions(onSend = { store.send() }),
            )
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                TextButton(onClick = {
                    keyboard = if (keyboard == ComposerKeyboard.SYSTEM) ComposerKeyboard.TOOLS else ComposerKeyboard.SYSTEM
                    if (keyboard == ComposerKeyboard.TOOLS) focusManager.clearFocus(force = true) else focusRequester.requestFocus()
                }) {
                    Text(if (keyboard == ComposerKeyboard.SYSTEM) "Tools" else "Text")
                }
                Button(onClick = store::send, enabled = state.canSend) { Text("Send") }
            }
        }
        if (keyboard == ComposerKeyboard.TOOLS) {
            ToolsKeyboard(
                selected = selectedToolsTab,
                onSelect = { selectedToolsTab = it },
                onSendKeys = attach::sendAgentKeys,
                snippets = snippets,
                skills = skills,
                agent = agent,
                onInsert = store::insertIntoDraft,
                onPickPhoto = onPickPhoto,
                onPickFile = onPickFile,
                onManageSnippets = onManageSnippets,
                onPaste = {
                    clipboard.getText()?.text?.let { pasted ->
                        pendingPaste = pasted
                    }
                },
            )
        }
        attach.uiState.collectAsState().value.controlError?.let { error ->
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)) {
                Text(error, modifier = Modifier.weight(1f), color = MaterialTheme.colorScheme.error)
                TextButton(onClick = attach::clearControlError) { Text("Dismiss") }
            }
        }
    }

    pendingPaste?.let { text ->
        PasteReviewDialog(
            text = text,
            onDismiss = { pendingPaste = null },
            onInsert = {
                store.insertIntoDraft(text)
                pendingPaste = null
            },
        )
    }
}

@Composable
private fun ComposerMessageStatus(
    message: ComposerMessage,
    onRetry: () -> Unit,
    onRestore: () -> Unit,
) {
    val label = when (val delivery = message.state) {
        ComposerDeliveryState.Sending -> "Delivering…"
        is ComposerDeliveryState.Delivered -> when (delivery.progress) {
            ComposerAgentProgress.Acknowledged -> "Delivered"
            ComposerAgentProgress.AgentBusy -> "Delivered — Agent is busy"
            ComposerAgentProgress.Working -> "Delivered — Agent is working"
            ComposerAgentProgress.Done -> "Delivered — Agent finished"
        }
        is ComposerDeliveryState.Failed -> delivery.message
    }
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(label, modifier = Modifier.weight(1f), style = MaterialTheme.typography.labelMedium)
        if (message.state is ComposerDeliveryState.Failed) {
            TextButton(onClick = onRetry) { Text("Retry") }
            TextButton(onClick = onRestore) { Text("Restore") }
        }
    }
}

@Composable
private fun ToolsKeyboard(
    selected: ToolsTab,
    onSelect: (ToolsTab) -> Unit,
    onSendKeys: (List<String>) -> Unit,
    snippets: SnippetStore,
    skills: SkillsPaneStore,
    agent: ConsoleAgent,
    onInsert: (String) -> Unit,
    onPickPhoto: () -> Unit,
    onPickFile: () -> Unit,
    onManageSnippets: () -> Unit,
    onPaste: () -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ToolsTab.entries.forEach { tab ->
                FilterChip(
                    selected = tab == selected,
                    onClick = { onSelect(tab) },
                    label = { Text(tab.name.lowercase().replaceFirstChar { it.uppercase() }) },
                )
            }
        }
        when (selected) {
            ToolsTab.CONTROLS -> ControlsPad(
                onSendKeys = onSendKeys,
                onPickPhoto = onPickPhoto,
                onPickFile = onPickFile,
                onPaste = onPaste,
            )
            ToolsTab.SNIPPETS -> snippets.let {
                dev.bybee.heeler.snippets.SnippetsKeyboardPane(
                    store = it,
                    onInsert = onInsert,
                    onManage = onManageSnippets,
                    modifier = Modifier.padding(top = 8.dp),
                )
            }
            ToolsTab.SKILLS -> SkillsPane(
                store = skills,
                hostId = agent.hostId,
                kind = agent.kind,
                projectRoot = agent.skillsProjectRoot,
                onInsert = onInsert,
                modifier = Modifier.padding(top = 8.dp),
            )
        }
    }
}

@Composable
private fun ControlsPad(
    onSendKeys: (List<String>) -> Unit,
    onPickPhoto: () -> Unit,
    onPickFile: () -> Unit,
    onPaste: () -> Unit,
) {
    val controls = listOf(
        "Esc" to listOf("esc"),
        "Tab" to listOf("tab"),
        "Ctrl+C" to listOf("ctrl+c"),
        "←" to listOf("left"),
        "↑" to listOf("up"),
        "↓" to listOf("down"),
        "→" to listOf("right"),
        "PgUp" to listOf("pageup"),
        "PgDn" to listOf("pagedown"),
    )
    Column(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 8.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.fillMaxWidth()) {
            controls.take(3).forEach { (label, keys) ->
                OutlinedButton(onClick = { onSendKeys(keys) }, modifier = Modifier.weight(1f)) { Text(label) }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.fillMaxWidth()) {
            controls.drop(3).take(4).forEach { (label, keys) ->
                OutlinedButton(onClick = { onSendKeys(keys) }, modifier = Modifier.weight(1f)) { Text(label) }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.fillMaxWidth()) {
            controls.takeLast(2).forEach { (label, keys) ->
                OutlinedButton(onClick = { onSendKeys(keys) }, modifier = Modifier.weight(1f)) { Text(label) }
            }
            OutlinedButton(onClick = onPaste, modifier = Modifier.weight(1f)) { Text("Paste") }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.fillMaxWidth()) {
            OutlinedButton(onClick = onPickPhoto, modifier = Modifier.weight(1f)) { Text("Add Photo") }
            OutlinedButton(onClick = onPickFile, modifier = Modifier.weight(1f)) { Text("Add File") }
        }
    }
}

@Composable
private fun PasteReviewDialog(text: String, onDismiss: () -> Unit, onInsert: () -> Unit) {
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Review Paste") },
        text = {
            Column {
                Text("${text.lineSequence().count()} lines, ${text.length} characters")
                Text(text, modifier = Modifier.padding(top = 8.dp), maxLines = 10)
            }
        },
        confirmButton = { Button(onClick = onInsert) { Text("Insert into Composer") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
