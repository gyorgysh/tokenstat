// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.chrome.HideTabBar

import ai.tokenstat.tokenstat.ui.chrome.HideTopBar

import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.components.cardRadiusDp
import ai.tokenstat.tokenstat.ui.logic.EditorConflict
import ai.tokenstat.tokenstat.ui.logic.EditorFind
import ai.tokenstat.tokenstat.ui.logic.EditorSave
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/// One file as a full page, port of the iOS phone `ClientFileEditor`: find
/// and replace, save states under the buffer, conflict handling when the host
/// copy moved, and a discard confirm. The host is re-read before every save
/// over `workspace.read`; the draft goes through `workspace.write`.
@Composable
fun WorkspaceFileEditorPage(
    model: AppViewModel,
    peer: String,
    workspace: String,
    folderName: String,
    hostLabel: String,
    path: String,
    modifier: Modifier = Modifier,
    onClose: () -> Unit = {},
    onSavedFile: () -> Unit = {},
) {
    // Its own header and its own way out, so the app chrome steps aside.
    HideTopBar()
    HideTabBar()
    val colors = LocalTsColors.current
    val scope = rememberCoroutineScope()
    var field by remember(path) { mutableStateOf(TextFieldValue("")) }
    var savedText by remember(path) { mutableStateOf<String?>(null) }
    var savedAt by remember(path) { mutableStateOf<Long?>(null) }
    var loading by remember(path) { mutableStateOf(true) }
    var saving by remember(path) { mutableStateOf(false) }
    var error by remember(path) { mutableStateOf<String?>(null) }
    var conflictHost by remember(path) { mutableStateOf<String?>(null) }
    var confirmDiscard by remember(path) { mutableStateOf(false) }
    var findOpen by remember(path) { mutableStateOf(false) }
    var query by remember(path) { mutableStateOf("") }
    var replaceText by remember(path) { mutableStateOf("") }
    var replacing by remember(path) { mutableStateOf(false) }
    var matchIndex by remember(path) { mutableStateOf(0) }

    val dirty = savedText != null && field.text != savedText
    val matches by remember(field.text, query) { derivedStateOf { EditorFind.matches(field.text, query) } }
    val safeIndex = if (matches.isEmpty()) 0 else matchIndex.coerceIn(0, matches.lastIndex)

    suspend fun load() {
        loading = true
        runCatching {
            model.workspaceSection(peer, "workspace.read", buildJsonObject {
                put("id", workspace); put("path", path)
            }) as? JsonObject
        }.onSuccess { file ->
            val content = file?.get("content") as? JsonPrimitive
                ?: file?.get("text") as? JsonPrimitive
            if (content?.contentOrNull != null) {
                field = TextFieldValue(content.contentOrNull.orEmpty())
                savedText = content.contentOrNull.orEmpty()
                error = null
            } else {
                error = "That file is not in this folder any more."
            }
        }.onFailure { error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
        loading = false
    }

    suspend fun save() {
        val draft = field.text
        val saved = savedText ?: return
        if (saving || conflictHost != null) return
        saving = true
        try {
            val host = runCatching {
                model.workspaceSection(peer, "workspace.read", buildJsonObject {
                    put("id", workspace); put("path", path)
                }) as? JsonObject
            }.getOrNull()?.let {
                ((it["content"] as? JsonPrimitive) ?: (it["text"] as? JsonPrimitive))?.contentOrNull
            }
            if (host == null) {
                error = "Could not re-read this file on the host, so the save waits. Your edits are kept."
                return
            }
            when (EditorSave.decide(host, draft, saved)) {
                EditorSave.Outcome.CONFLICT -> {
                    error = null
                    conflictHost = host
                    return
                }
                EditorSave.Outcome.ALREADY_SAVED -> {
                    savedText = draft
                    savedAt = System.currentTimeMillis()
                    error = null
                    return
                }
                EditorSave.Outcome.SAVE -> Unit
            }
            runCatching {
                model.workspaceSection(peer, "workspace.write", buildJsonObject {
                    put("id", workspace); put("path", path); put("content", draft)
                })
            }.onSuccess {
                savedText = draft
                savedAt = System.currentTimeMillis()
                error = null
                onSavedFile()
            }.onFailure { error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
        } finally {
            saving = false
        }
    }

    fun goToMatch(index: Int) {
        if (matches.isEmpty()) return
        val at = index.coerceIn(0, matches.lastIndex)
        matchIndex = at
        val range = matches[at]
        field = field.copy(selection = TextRange(range.first, range.last + 1))
    }

    fun requestClose() {
        if (dirty) confirmDiscard = true else onClose()
    }

    LaunchedEffect(path) { load() }

    Column(modifier.fillMaxSize()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = ::requestClose, enabled = !saving) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back to $folderName")
            }
            Column(Modifier.weight(1f)) {
                Text(
                    path.substringAfterLast('/').ifBlank { path },
                    style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    path,
                    style = TsType.mono(11),
                    color = colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            IconButton(onClick = { findOpen = !findOpen }) {
                Icon(Icons.Default.Search, "Find in file", tint = colors.accent)
            }
            TsAccentButton(
                label = if (saving) "Saving…" else "Save",
                small = true,
                enabled = !saving && dirty && conflictHost == null,
                onClick = { scope.launch { save() } },
            )
        }
        if (findOpen) {
            EditorFindBar(
                query = query,
                onQuery = { query = it; matchIndex = 0 },
                countLabel = EditorFind.countLabel(safeIndex, matches.size),
                canNavigate = matches.isNotEmpty(),
                onPrevious = { goToMatch(EditorFind.prevIndex(safeIndex, matches.size)) },
                onNext = { goToMatch(EditorFind.nextIndex(safeIndex, matches.size)) },
                replacing = replacing,
                onToggleReplace = { replacing = !replacing },
                replaceText = replaceText,
                onReplaceText = { replaceText = it },
                onReplace = {
                    val done = EditorFind.replaceFirst(field.text, query, replaceText)
                    if (done.count > 0) {
                        field = TextFieldValue(done.text, TextRange(field.selection.start, field.selection.start))
                    }
                },
                onReplaceAll = {
                    val done = EditorFind.replaceAll(field.text, query, replaceText)
                    if (done.count > 0) field = TextFieldValue(done.text)
                },
            )
        }
        val host = conflictHost
        if (host != null) {
            EditorConflictCard(
                draft = field.text,
                hostContent = host,
                onReload = {
                    field = TextFieldValue(host)
                    savedText = host
                    conflictHost = null
                    error = null
                },
                onKeep = {
                    conflictHost = null
                    error = null
                    val sent = field.text
                    scope.launch {
                        saving = true
                        try {
                            runCatching {
                                model.workspaceSection(peer, "workspace.write", buildJsonObject {
                                    put("id", workspace); put("path", path); put("content", sent)
                                })
                            }.onSuccess {
                                savedText = sent
                                savedAt = System.currentTimeMillis()
                                onSavedFile()
                            }.onFailure {
                                error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel)
                            }
                        } finally {
                            saving = false
                        }
                    }
                },
            )
        }
        if (loading) {
            Text("Loading…", color = colors.textSecondary, modifier = Modifier.padding(Space.m))
        } else if (savedText == null && error != null) {
            StickyErrorCard(
                message = error!!,
                modifier = Modifier.padding(Space.m),
                onRetry = { scope.launch { load() } },
                onDismiss = { error = null },
            )
        } else {
            BasicTextField(
                value = field,
                onValueChange = { field = it },
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .padding(Space.m)
                    .verticalScroll(rememberScrollState()),
                textStyle = TsType.mono(13).copy(color = colors.textPrimary),
                cursorBrush = androidx.compose.ui.graphics.SolidColor(colors.accent),
            )
        }
        EditorStatusBar(
            error = error,
            dirty = dirty,
            savedAt = savedAt,
            onRetry = { scope.launch { save() } },
            onDismissError = { error = null },
        )
    }
    if (confirmDiscard) {
        AlertDialog(
            onDismissRequest = { confirmDiscard = false },
            title = { Text("Discard changes?") },
            text = { Text("This file has edits that are not saved on the host.") },
            confirmButton = {
                TextButton(onClick = { confirmDiscard = false; onClose() }) {
                    Text("Discard", color = LocalTsColors.current.danger)
                }
            },
            dismissButton = { TextButton(onClick = { confirmDiscard = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun EditorFindBar(
    query: String,
    onQuery: (String) -> Unit,
    countLabel: String?,
    canNavigate: Boolean,
    onPrevious: () -> Unit,
    onNext: () -> Unit,
    replacing: Boolean,
    onToggleReplace: () -> Unit,
    replaceText: String,
    onReplaceText: (String) -> Unit,
    onReplace: () -> Unit,
    onReplaceAll: () -> Unit,
) {
    val colors = LocalTsColors.current
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = Space.m)
            .clip(RoundedCornerShape(cardRadiusDp))
            .background(colors.panel)
            .padding(Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
            OutlinedTextField(
                query,
                onQuery,
                modifier = Modifier.weight(1f),
                placeholder = { Text("Find in file") },
                singleLine = true,
            )
            countLabel?.let {
                Text(it, style = TsType.numeric(12), color = colors.textTertiary, maxLines = 1)
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
            IconButton(onClick = onPrevious, enabled = canNavigate, modifier = Modifier.size(44.dp)) {
                Icon(Icons.Default.KeyboardArrowUp, "Previous match")
            }
            IconButton(onClick = onNext, enabled = canNavigate, modifier = Modifier.size(44.dp)) {
                Icon(Icons.Default.KeyboardArrowDown, "Next match")
            }
            Spacer(Modifier.weight(1f))
            TsSecondaryButton(
                label = if (replacing) "Hide replace" else "Replace",
                small = true,
                onClick = onToggleReplace,
            )
        }
        if (replacing) {
            OutlinedTextField(
                replaceText,
                onReplaceText,
                modifier = Modifier.fillMaxWidth(),
                placeholder = { Text("Replace with") },
                singleLine = true,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                TsSecondaryButton(label = "Replace", small = true, enabled = canNavigate, onClick = onReplace)
                TsSecondaryButton(label = "Replace all", small = true, enabled = canNavigate, onClick = onReplaceAll)
            }
        }
    }
}

@Composable
private fun EditorConflictCard(
    draft: String,
    hostContent: String,
    onReload: () -> Unit,
    onKeep: () -> Unit,
) {
    val colors = LocalTsColors.current
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = Space.m)
            .padding(top = Space.s)
            .clip(RoundedCornerShape(cardRadiusDp))
            .background(colors.panel)
            .padding(Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Text(
            "This file changed on the host.",
            style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold),
            color = colors.textPrimary,
        )
        Text(
            EditorConflict.summary(draft, hostContent),
            style = TextStyle(fontSize = 12.sp),
            color = colors.textSecondary,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
            TsSecondaryButton(label = "Reload host", small = true, onClick = onReload)
            TsAccentButton(label = "Keep my draft", small = true, onClick = onKeep)
        }
    }
}

/// The line under the buffer: unsaved state, save outcome. A failed save is
/// the loud case and stays until retried or dismissed.
@Composable
private fun EditorStatusBar(
    error: String?,
    dirty: Boolean,
    savedAt: Long?,
    onRetry: () -> Unit,
    onDismissError: () -> Unit,
) {
    val colors = LocalTsColors.current
    if (error != null) {
        StickyErrorCard(
            message = error,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = Space.m, vertical = Space.s),
            onRetry = onRetry,
            onDismiss = onDismissError,
        )
        return
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.s),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = Space.m, vertical = Space.s),
    ) {
        if (dirty) {
            Text("● Unsaved", style = TextStyle(fontSize = 12.sp), color = colors.warning)
        } else if (savedAt != null) {
            val time = remember(savedAt) {
                SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(savedAt))
            }
            Text("Saved $time", style = TextStyle(fontSize = 12.sp), color = colors.textTertiary)
        }
        Spacer(Modifier.weight(1f))
    }
}
