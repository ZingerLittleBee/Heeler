package dev.bybee.heeler.settings

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.floatPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.bybee.heeler.BuildConfig
import dev.bybee.heeler.core.terminal.NativeTerminal
import dev.bybee.heeler.notifications.NotificationRelaySettings
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

private val Context.terminalAppearanceDataStore: DataStore<Preferences> by preferencesDataStore(
    name = "terminal_appearance",
)
private val terminalThemeKey = stringPreferencesKey("theme")
private val terminalFontSizeKey = floatPreferencesKey("font_size_sp")

/** The terminal palette choice deliberately has no connection lifecycle implications. */
enum class TerminalTheme(val label: String) {
    DARK("Dark"),
    LIGHT("Light"),
}

data class TerminalAppearance(
    val theme: TerminalTheme = TerminalTheme.DARK,
    val fontSizeSp: Float = 14f,
)

/**
 * Application-wide terminal appearance settings. Agent Detail observes [state]
 * and applies [applyToTerminal] to an already-open handle; it never reconnects
 * SSH or reattaches a terminal.
 */
class TerminalAppearanceStore(context: Context) : ViewModel() {
    private val dataStore = context.applicationContext.terminalAppearanceDataStore
    private val _state = kotlinx.coroutines.flow.MutableStateFlow(TerminalAppearance())
    val state: kotlinx.coroutines.flow.StateFlow<TerminalAppearance> = _state
    private var pendingPersistence: Job? = null

    init {
        viewModelScope.launch {
            val preferences = runCatching { dataStore.data.first() }.getOrNull() ?: return@launch
            val theme = preferences[terminalThemeKey]
                ?.let { value -> TerminalTheme.entries.firstOrNull { it.name == value } }
                ?: TerminalTheme.DARK
            val fontSize = preferences[terminalFontSizeKey]
                ?.takeIf { it.isFinite() }
                ?.coerceIn(MINIMUM_FONT_SIZE_SP, MAXIMUM_FONT_SIZE_SP)
                ?: DEFAULT_FONT_SIZE_SP
            _state.value = TerminalAppearance(theme, fontSize)
        }
    }

    fun setTheme(theme: TerminalTheme) {
        if (_state.value.theme == theme) return
        _state.value = _state.value.copy(theme = theme)
        schedulePersistence()
    }

    /** Also used by the terminal pinch-zoom callback. */
    fun setFontSizeSp(size: Float) {
        val bounded = size.coerceIn(MINIMUM_FONT_SIZE_SP, MAXIMUM_FONT_SIZE_SP)
        if (_state.value.fontSizeSp == bounded) return
        _state.value = _state.value.copy(fontSizeSp = bounded)
        schedulePersistence()
    }

    fun adjustZoom(deltaSp: Float) = setFontSizeSp(_state.value.fontSizeSp + deltaSp)

    /** Must be called from the same UI thread that owns [handle]. */
    fun applyToTerminal(handle: Long) {
        if (handle == 0L) return
        val colors = colorsFor(_state.value.theme)
        NativeTerminal.setColorScheme(handle, if (_state.value.theme == TerminalTheme.LIGHT) 0 else 1)
        NativeTerminal.setDefaultColors(handle, colors.foreground, colors.background, colors.cursor, null)
    }

    private fun schedulePersistence() {
        pendingPersistence?.cancel()
        val appearance = _state.value
        pendingPersistence = viewModelScope.launch {
            // Pinch zoom emits many values per frame; only the settled setting needs disk I/O.
            delay(PERSISTENCE_DEBOUNCE_MS)
            dataStore.edit { preferences ->
                preferences[terminalThemeKey] = appearance.theme.name
                preferences[terminalFontSizeKey] = appearance.fontSizeSp
            }
        }
    }

    private data class TerminalColors(
        val foreground: IntArray,
        val background: IntArray,
        val cursor: IntArray,
    )

    private fun colorsFor(theme: TerminalTheme): TerminalColors = when (theme) {
        TerminalTheme.DARK -> TerminalColors(
            foreground = intArrayOf(220, 223, 230),
            background = intArrayOf(20, 22, 27),
            cursor = intArrayOf(220, 223, 230),
        )
        TerminalTheme.LIGHT -> TerminalColors(
            foreground = intArrayOf(35, 38, 43),
            background = intArrayOf(250, 250, 252),
            cursor = intArrayOf(35, 38, 43),
        )
    }

    private companion object {
        const val DEFAULT_FONT_SIZE_SP = 14f
        const val MINIMUM_FONT_SIZE_SP = 10f
        const val MAXIMUM_FONT_SIZE_SP = 28f
        const val PERSISTENCE_DEBOUNCE_MS = 250L
    }
}

/** Settings route content, including live terminal appearance and relay override controls. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    appearanceStore: TerminalAppearanceStore,
    relaySettings: NotificationRelaySettings,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val appearance by appearanceStore.state.collectAsState()
    val relayRaw by relaySettings.rawValue.collectAsState()
    val relayInvalid by relaySettings.hasInvalidEntry.collectAsState()
    var relayDraft by remember(relayRaw) { mutableStateOf(relayRaw) }
    val scope = rememberCoroutineScope()
    var acknowledgementsOpen by remember { mutableStateOf(false) }
    val context = LocalContext.current

    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                navigationIcon = { TextButton(onClick = onClose) { Text("Done") } },
            )
        },
    ) { padding ->
        Column(
            Modifier.padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            SettingsSection("Terminal appearance") {
                Text("Terminal theme", fontWeight = FontWeight.SemiBold)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    ThemeChoice(
                        label = TerminalTheme.DARK.label,
                        selected = appearance.theme == TerminalTheme.DARK,
                        onClick = { appearanceStore.setTheme(TerminalTheme.DARK) },
                    )
                    ThemeChoice(
                        label = TerminalTheme.LIGHT.label,
                        selected = appearance.theme == TerminalTheme.LIGHT,
                        onClick = { appearanceStore.setTheme(TerminalTheme.LIGHT) },
                    )
                }
                Text("Terminal text size: ${appearance.fontSizeSp.toInt()} sp", fontWeight = FontWeight.SemiBold)
                Slider(
                    value = appearance.fontSizeSp,
                    onValueChange = appearanceStore::setFontSizeSp,
                    valueRange = 10f..28f,
                    steps = 17,
                    modifier = Modifier.fillMaxWidth(),
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = { appearanceStore.adjustZoom(-1f) }) { Text("Smaller") }
                    OutlinedButton(onClick = { appearanceStore.adjustZoom(1f) }) { Text("Larger") }
                }
                Text(
                    "Pinching a terminal changes this value too. Appearance updates an open terminal in place.",
                    style = MaterialTheme.typography.bodySmall,
                )
            }

            SettingsSection("Notifications") {
                Text("Push relay URL override", fontWeight = FontWeight.SemiBold)
                OutlinedTextField(
                    value = relayDraft,
                    onValueChange = { relayDraft = it },
                    label = { Text("Use the default relay when blank") },
                    singleLine = true,
                    isError = relayInvalid,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedButton(
                    onClick = { scope.launch { relaySettings.setRawValue(relayDraft) } },
                ) { Text("Apply relay override") }
                if (relayInvalid) {
                    Text(
                        "Enter an absolute HTTP(S) relay URL or clear this value to use the default.",
                        color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
                Text(
                    "A custom relay receives encrypted notification envelopes. Read the privacy details before changing it.",
                    style = MaterialTheme.typography.bodySmall,
                )
            }

            SettingsSection("About") {
                Text("Version", fontWeight = FontWeight.SemiBold)
                Text("${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})")
                HorizontalDivider()
                TextButton(onClick = { acknowledgementsOpen = true }) { Text("Acknowledgements") }
                TextButton(onClick = {
                    context.startActivity(
                        Intent(Intent.ACTION_VIEW, Uri.parse(PRIVACY_POLICY_URL)),
                    )
                }) { Text("Read privacy details") }
            }
        }
    }

    if (acknowledgementsOpen) {
        AcknowledgementsDialog(onDismiss = { acknowledgementsOpen = false })
    }
}

@Composable
private fun SettingsSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(title, style = MaterialTheme.typography.titleMedium)
        Card(modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp), content = content)
        }
    }
}

@Composable
private fun ThemeChoice(label: String, selected: Boolean, onClick: () -> Unit) {
    if (selected) FilledTonalButton(onClick = onClick) { Text(label) }
    else OutlinedButton(onClick = onClick) { Text(label) }
}

private data class LicenseNotice(val component: String, val license: String, val text: String)

@Composable
private fun AcknowledgementsDialog(onDismiss: () -> Unit) {
    var selected by remember { mutableStateOf<LicenseNotice?>(null) }
    val notice = selected
    if (notice != null) {
        AlertDialog(
            onDismissRequest = { selected = null },
            title = { Text(notice.component) },
            text = {
                Text(
                    notice.text,
                    fontFamily = FontFamily.Monospace,
                    modifier = Modifier.widthIn(max = 600.dp).verticalScroll(rememberScrollState()),
                )
            },
            confirmButton = { TextButton(onClick = { selected = null }) { Text("Back") } },
        )
    } else {
        AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text("Acknowledgements") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Heeler redistributes these components. Each licence is reproduced in full.")
                    LICENSE_NOTICES.forEach { entry ->
                        TextButton(onClick = { selected = entry }, modifier = Modifier.fillMaxWidth()) {
                            Column(Modifier.fillMaxWidth()) {
                                Text(entry.component, fontWeight = FontWeight.SemiBold)
                                Text(entry.license, style = MaterialTheme.typography.bodySmall)
                            }
                        }
                    }
                }
            },
            confirmButton = { TextButton(onClick = onDismiss) { Text("Close") } },
        )
    }
}

private const val PRIVACY_POLICY_URL = "https://github.com/ZingerLittleBee/Heeler/blob/main/PRIVACY.md"

private val LICENSE_NOTICES = listOf(
    LicenseNotice(
        component = "chuchu",
        license = "MIT License",
        text = """MIT License

Copyright (c) 2026 jossephus

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.""",
    ),
    LicenseNotice(
        component = "ghostty-vt",
        license = "MIT License",
        text = """MIT License

Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.""",
    ),
    LicenseNotice(
        component = "libssh2",
        license = "BSD-3-Clause",
        text = """Copyright (C) 2004-2007 Sara Golemon <sarag@libssh2.org>
Copyright (C) 2005,2006 Mikhail Gusarov <dottedmag@dottedmag.net>
Copyright (C) 2006-2007 The Written Word, Inc.
Copyright (C) 2007 Eli Fant <elifantu@mail.ru>
Copyright (C) 2009-2023 Daniel Stenberg
Copyright (C) 2008, 2009 Simon Josefsson
Copyright (C) 2000 Markus Friedl
Copyright (C) 2015 Microsoft Corp.
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
this list of conditions and the following disclaimer in the documentation
and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
contributors may be used to endorse or promote products derived from this
software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.""",
    ),
)
