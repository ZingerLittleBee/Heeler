package dev.bybee.heeler.snippets

import android.content.Context
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.preferencesDataStore
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.bybee.heeler.core.transport.TerminalTextSafety
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.IOException
import java.util.UUID

private val Context.snippetsDataStore: DataStore<Preferences> by preferencesDataStore(name = "snippets")
private val snippetsCatalogKey = stringPreferencesKey("catalog")

sealed class SnippetValidationError(message: String) : IllegalArgumentException(message) {
    data object EmptyBody : SnippetValidationError("Snippet text cannot be empty.")
    data class BodyTooLong(val limit: Int) :
        SnippetValidationError("Snippet text cannot exceed $limit characters.")

    data object UnsupportedControlCharacters :
        SnippetValidationError("Snippet text contains unsupported control characters.")
}

sealed class SnippetStoreError(message: String) : IllegalStateException(message) {
    data object UnknownSnippet : SnippetStoreError("This Snippet no longer exists.")
    data object CatalogUnreadable : SnippetStoreError("Saved Snippets could not be read.")
}

/** A global, ordered phrase. Tapping it always edits a draft; it never sends. */
@Serializable
data class Snippet(
    val id: String,
    val title: String?,
    val body: String,
) {
    val displayTitle: String get() = title ?: body
    val displaySubtitle: String? get() = title?.let { body }

    companion object {
        const val BODY_CHARACTER_LIMIT = 4_000

        fun create(
            title: String?,
            body: String,
            id: String = UUID.randomUUID().toString(),
        ): Snippet {
            val normalizedBody = TerminalTextSafety.normalizingNewlines(body)
            if (!normalizedBody.isNotBlank()) throw SnippetValidationError.EmptyBody
            if (normalizedBody.length > BODY_CHARACTER_LIMIT) {
                throw SnippetValidationError.BodyTooLong(BODY_CHARACTER_LIMIT)
            }
            if (!TerminalTextSafety.containsOnlySafeScalars(normalizedBody)) {
                throw SnippetValidationError.UnsupportedControlCharacters
            }
            return Snippet(
                id = id,
                title = title?.trim()?.takeIf { it.isNotEmpty() },
                body = normalizedBody,
            )
        }
    }
}

@Serializable
private data class PersistedSnippetCatalog(
    val version: Int,
    val snippets: List<Snippet>,
)

data class SnippetCatalogState(
    val snippets: List<Snippet> = emptyList(),
    val isLoading: Boolean = true,
    val loadError: SnippetStoreError? = null,
)

/**
 * DataStore-backed global snippet catalog. Mutations are suspending so callers
 * get persistence failure rather than optimistic local state that disappears
 * after process death.
 */
class SnippetStore(context: Context) : ViewModel() {
    private val dataStore = context.applicationContext.snippetsDataStore
    private val json = Json { ignoreUnknownKeys = false; encodeDefaults = true }
    private val mutationMutex = Mutex()
    private val initialized = CompletableDeferred<Unit>()
    private val _state = kotlinx.coroutines.flow.MutableStateFlow(SnippetCatalogState())
    val state: kotlinx.coroutines.flow.StateFlow<SnippetCatalogState> = _state

    init {
        viewModelScope.launch {
            _state.value = try {
                val raw = dataStore.firstValue(snippetsCatalogKey)
                SnippetCatalogState(snippets = decodeCatalog(raw), isLoading = false)
            } catch (_: Exception) {
                SnippetCatalogState(isLoading = false, loadError = SnippetStoreError.CatalogUnreadable)
            }
            initialized.complete(Unit)
        }
    }

    suspend fun add(title: String?, body: String): Snippet {
        val snippet = Snippet.create(title, body)
        mutate { it + snippet }
        return snippet
    }

    suspend fun update(id: String, title: String?, body: String): Snippet {
        val updated = Snippet.create(title, body, id)
        mutate { current ->
            val index = current.indexOfFirst { it.id == id }
            if (index < 0) throw SnippetStoreError.UnknownSnippet
            current.toMutableList().apply { set(index, updated) }
        }
        return updated
    }

    suspend fun remove(id: String) {
        mutate { current ->
            val index = current.indexOfFirst { it.id == id }
            if (index < 0) throw SnippetStoreError.UnknownSnippet
            current.toMutableList().apply { removeAt(index) }
        }
    }

    /** Moves an item to its resulting absolute index, retaining the user's thumb-memory order. */
    suspend fun move(fromIndex: Int, toIndex: Int) {
        mutate { current ->
            if (fromIndex !in current.indices) throw SnippetStoreError.UnknownSnippet
            val reordered = current.toMutableList()
            val moved = reordered.removeAt(fromIndex)
            reordered.add(toIndex.coerceIn(0, reordered.size), moved)
            reordered
        }
    }

    fun matching(query: String): List<Snippet> {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return state.value.snippets
        return state.value.snippets.filter {
            it.title?.contains(trimmed, ignoreCase = true) == true ||
                it.body.contains(trimmed, ignoreCase = true)
        }
    }

    private suspend fun mutate(transform: (List<Snippet>) -> List<Snippet>) {
        initialized.await()
        mutationMutex.withLock {
            val current = state.value
            if (current.loadError != null) throw SnippetStoreError.CatalogUnreadable
            val next = transform(current.snippets)
            val encoded = json.encodeToString(PersistedSnippetCatalog(SCHEMA_VERSION, next))
            dataStore.edit { preferences -> preferences[snippetsCatalogKey] = encoded }
            _state.value = SnippetCatalogState(snippets = next, isLoading = false)
        }
    }

    private fun decodeCatalog(raw: String?): List<Snippet> {
        if (raw == null) return emptyList()
        val catalog = json.decodeFromString<PersistedSnippetCatalog>(raw)
        if (catalog.version != SCHEMA_VERSION) throw SnippetStoreError.CatalogUnreadable
        return catalog.snippets.map { Snippet.create(it.title, it.body, it.id) }
    }

    private companion object {
        const val SCHEMA_VERSION = 1
    }
}

private suspend fun DataStore<Preferences>.firstValue(key: Preferences.Key<String>): String? {
    return data.first()[key]
}

/** Full search, add, edit, delete, and reorder surface for the global Snippet catalog. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SnippetsManagementScreen(
    store: SnippetStore,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val state by store.state.collectAsState()
    var query by remember { mutableStateOf("") }
    var editor by remember { mutableStateOf<SnippetEditorTarget?>(null) }
    var actionError by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val snippets = store.matching(query)

    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text("Snippets") },
                navigationIcon = { TextButton(onClick = onClose) { Text("Done") } },
                actions = { TextButton(onClick = { editor = SnippetEditorTarget.New }) { Text("Add") } },
            )
        },
    ) { padding ->
        Column(Modifier.padding(padding).padding(horizontal = 16.dp)) {
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                label = { Text("Search Snippets") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
            )
            actionError?.let { Text(it, Modifier.padding(bottom = 8.dp)) }
            when {
                state.isLoading -> Text("Loading Snippets…", Modifier.padding(vertical = 24.dp))
                state.loadError != null -> Text(
                    "Saved Snippets could not be read. They have not been changed.",
                    Modifier.padding(vertical = 24.dp),
                )
                snippets.isEmpty() && query.isNotBlank() -> Text(
                    "No Snippets match “$query”.",
                    Modifier.padding(vertical = 24.dp),
                )
                snippets.isEmpty() -> EmptySnippets(onAdd = { editor = SnippetEditorTarget.New })
                else -> LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    itemsIndexed(snippets, key = { _, item -> item.id }) { _, snippet ->
                        val canonicalIndex = state.snippets.indexOfFirst { it.id == snippet.id }
                        SnippetManagementRow(
                            snippet = snippet,
                            canMove = query.isBlank(),
                            onEdit = { editor = SnippetEditorTarget.Existing(snippet) },
                            onDelete = {
                                scope.launch {
                                    try {
                                        store.remove(snippet.id)
                                        actionError = null
                                    } catch (failure: SnippetStoreError) {
                                        actionError = failure.message
                                    } catch (_: IOException) {
                                        actionError = "Removing this Snippet failed."
                                    }
                                }
                            },
                            onMoveUp = {
                                if (canonicalIndex > 0) scope.launch {
                                    try {
                                        store.move(canonicalIndex, canonicalIndex - 1)
                                        actionError = null
                                    } catch (failure: SnippetStoreError) {
                                        actionError = failure.message
                                    } catch (_: IOException) {
                                        actionError = "Reordering Snippets failed."
                                    }
                                }
                            },
                            onMoveDown = {
                                if (canonicalIndex >= 0 && canonicalIndex < state.snippets.lastIndex) scope.launch {
                                    try {
                                        store.move(canonicalIndex, canonicalIndex + 1)
                                        actionError = null
                                    } catch (failure: SnippetStoreError) {
                                        actionError = failure.message
                                    } catch (_: IOException) {
                                        actionError = "Reordering Snippets failed."
                                    }
                                }
                            },
                        )
                    }
                }
            }
        }
    }

    editor?.let { target ->
        SnippetEditorDialog(
            target = target,
            store = store,
            onDismiss = { editor = null },
        )
    }
}

private sealed interface SnippetEditorTarget {
    data object New : SnippetEditorTarget
    data class Existing(val snippet: Snippet) : SnippetEditorTarget
}

@Composable
private fun EmptySnippets(onAdd: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(vertical = 40.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text("No Snippets yet", fontWeight = FontWeight.SemiBold)
        Text("Save reusable prompts here. Tapping one only inserts it into the draft.")
        Button(onClick = onAdd) { Text("Add Snippet") }
    }
}

@Composable
private fun SnippetManagementRow(
    snippet: Snippet,
    canMove: Boolean,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
    onMoveUp: () -> Unit,
    onMoveDown: () -> Unit,
) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(snippet.displayTitle, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            snippet.displaySubtitle?.let { Text(it, maxLines = 2, overflow = TextOverflow.Ellipsis) }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = onEdit) { Text("Edit") }
                TextButton(onClick = onDelete) { Text("Delete") }
                if (canMove) {
                    TextButton(onClick = onMoveUp) { Text("Move up") }
                    TextButton(onClick = onMoveDown) { Text("Move down") }
                }
            }
        }
    }
}

@Composable
private fun SnippetEditorDialog(
    target: SnippetEditorTarget,
    store: SnippetStore,
    onDismiss: () -> Unit,
) {
    val original = (target as? SnippetEditorTarget.Existing)?.snippet
    var title by remember(target) { mutableStateOf(original?.title.orEmpty()) }
    var body by remember(target) { mutableStateOf(original?.body.orEmpty()) }
    var error by remember(target) { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (original == null) "New Snippet" else "Edit Snippet") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = title,
                    onValueChange = { title = it },
                    label = { Text("Title (optional)") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = body,
                    onValueChange = { body = it },
                    label = { Text("Snippet text") },
                    minLines = 5,
                    modifier = Modifier.fillMaxWidth(),
                )
                error?.let { Text(it) }
            }
        },
        confirmButton = {
            Button(onClick = {
                scope.launch {
                    try {
                        if (original == null) store.add(title, body) else store.update(original.id, title, body)
                        onDismiss()
                    } catch (failure: IllegalArgumentException) {
                        error = failure.message
                    } catch (failure: SnippetStoreError) {
                        error = failure.message
                    } catch (_: IOException) {
                        error = "Saving this Snippet failed."
                    }
                }
            }) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/** Compact tools-keyboard pane. Its only effect is [onInsert], never submission. */
@Composable
fun SnippetsKeyboardPane(
    store: SnippetStore,
    onInsert: (String) -> Unit,
    onManage: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val state by store.state.collectAsState()
    Column(modifier = modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (state.isLoading) {
            Text("Loading Snippets…", Modifier.padding(16.dp))
        } else if (state.snippets.isEmpty()) {
            Text("Save reusable prompts in Snippets.", Modifier.padding(16.dp))
        } else {
            LazyColumn(modifier = Modifier.weight(1f, fill = false), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                itemsIndexed(state.snippets, key = { _, snippet -> snippet.id }) { _, snippet ->
                    FilledTonalButton(
                        onClick = { onInsert(snippet.body) },
                        modifier = Modifier.fillMaxWidth().semantics {
                            contentDescription = "Insert ${snippet.displayTitle} without sending"
                        },
                    ) {
                        Column(Modifier.fillMaxWidth()) {
                            Text(snippet.displayTitle, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            snippet.displaySubtitle?.let {
                                Text(it, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                        }
                    }
                }
            }
        }
        OutlinedButton(onClick = onManage, modifier = Modifier.fillMaxWidth()) { Text("Manage Snippets") }
    }
}
