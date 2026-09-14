// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Notes
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.EmptyState
import ai.tokenstat.tokenstat.ui.components.RelativeTimeText
import ai.tokenstat.tokenstat.ui.components.SectionLabel
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsSearchField
import ai.tokenstat.tokenstat.ui.components.cardRadiusDp
import ai.tokenstat.tokenstat.ui.logic.NoteList
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import ai.tokenstat.tokenstat.ui.marks.EmptyArt
import ai.tokenstat.tokenstat.ui.marks.EmptyArtKind
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

private fun JsonObject.toNoteCard(): NoteList.NoteCard? {
    val id = str("id") ?: return null
    return NoteList.NoteCard(
        id = id,
        title = str("title") ?: "",
        body = str("notes") ?: "",
        column = str("column") ?: "backlog",
        createdAtMs = long("createdAtMs") ?: 0L,
    )
}

/// Small things worth keeping, for one folder, on the machine that owns it.
///
/// Ports `ClientWorkspaceNotesView`: quick capture at the top (return saves),
/// search, newest-first or A-Z sort, an archive behind a toggle, optimistic
/// rows swapped for the host card, edit sheet, delete confirm, and turning a
/// note into a task. A note is a `todo` card whose kind is `note`.
@Composable
fun NotesSection(
    model: AppViewModel,
    peer: String,
    workspace: String,
    modifier: Modifier = Modifier,
    folderName: String = "",
    hostLabel: String = "",
) {
    val scope = rememberCoroutineScope()
    var cards by remember { mutableStateOf<List<NoteList.NoteCard>>(emptyList()) }
    var draft by remember { mutableStateOf("") }
    var search by remember { mutableStateOf("") }
    var alphabetical by remember { mutableStateOf(false) }
    var showingArchive by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var loading by remember { mutableStateOf(true) }
    var pendingDelete by remember { mutableStateOf<NoteList.NoteCard?>(null) }
    var editing by remember { mutableStateOf<NoteList.NoteCard?>(null) }

    suspend fun load() {
        loading = true
        runCatching {
            model.workspaceSection(peer, "todo.list", buildJsonObject { put("includeArchived", true) })
        }.onSuccess { element ->
            val all = asObjects(element).ifEmpty { asObjects((element as? JsonObject)?.get("cards")) }
            cards = all.filter { (it.str("kind") ?: "task") == "note" }
                .filter { (it.str("workspaceId") ?: workspace) == workspace }
                .mapNotNull { it.toNoteCard() }
            error = null
        }.onFailure { error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
        loading = false
    }
    LaunchedEffect(workspace) { load() }

    val place = folderName.ifBlank { "this folder" }
    val notes = NoteList.visible(cards, showingArchive, search, alphabetical)
    val archivedCount = NoteList.archivedCount(cards)

    fun save() {
        val text = draft.trim()
        if (text.isEmpty()) return
        draft = ""
        val pending = NoteList.NoteCard(
            id = "pending:${java.util.UUID.randomUUID()}",
            title = text,
            body = "",
            column = "backlog",
            createdAtMs = System.currentTimeMillis(),
        )
        cards = cards + pending
        scope.launch {
            runCatching {
                model.workspaceSection(peer, "todo.create", buildJsonObject {
                    put("title", text)
                    put("kind", "note")
                    put("notes", "")
                    put("column", "backlog")
                    put("backend", "")
                    put("workspaceId", workspace)
                    put("budgetSeconds", 0)
                }) as JsonObject
            }.onSuccess { saved ->
                cards = cards.filter { it.id != pending.id } + listOfNotNull(saved.toNoteCard())
                error = null
            }.onFailure {
                cards = cards.filter { it.id != pending.id }
                if (draft.trim().isEmpty()) draft = text
                error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel)
            }
        }
    }

    fun move(note: NoteList.NoteCard, archived: Boolean) {
        scope.launch {
            runCatching {
                model.workspaceSection(peer, "todo.update", buildJsonObject {
                    put("id", note.id)
                    put("column", if (archived) NoteList.ARCHIVE_COLUMN else "backlog")
                }) as JsonObject
            }.onSuccess { updated ->
                updated.toNoteCard()?.let { fresh ->
                    cards = cards.map { if (it.id == fresh.id) fresh else it }
                }
                error = null
            }.onFailure { error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
        }
    }

    fun rename(note: NoteList.NoteCard, text: String) {
        if (text.isEmpty() || text == note.title) return
        scope.launch {
            runCatching {
                model.workspaceSection(peer, "todo.update", buildJsonObject {
                    put("id", note.id)
                    put("title", text)
                }) as JsonObject
            }.onSuccess { updated ->
                updated.toNoteCard()?.let { fresh ->
                    cards = cards.map { if (it.id == fresh.id) fresh else it }
                }
                error = null
            }.onFailure { error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
        }
    }

    fun convert(note: NoteList.NoteCard) {
        scope.launch {
            runCatching {
                model.workspaceSection(peer, "todo.update", buildJsonObject {
                    put("id", note.id)
                    put("column", "backlog")
                    put("kind", "task")
                    put("notes", note.body.ifBlank { note.title })
                })
            }.onSuccess {
                cards = cards.filter { it.id != note.id }
                error = null
            }.onFailure { error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
        }
    }

    fun delete(note: NoteList.NoteCard) {
        scope.launch {
            runCatching {
                model.workspaceSection(peer, "todo.remove", buildJsonObject { put("id", note.id) })
            }.onSuccess {
                cards = cards.filter { it.id != note.id }
                error = null
            }.onFailure { error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
        }
    }

    Column(modifier, verticalArrangement = Arrangement.spacedBy(Space.s)) {
        Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(cardRadiusDp))
                .background(LocalTsColors.current.panel)
                .padding(Space.m),
            verticalArrangement = Arrangement.spacedBy(Space.xs),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                OutlinedTextField(
                    draft,
                    { draft = it },
                    modifier = Modifier.weight(1f),
                    placeholder = { Text("Something worth remembering") },
                    singleLine = true,
                )
                TsAccentButton(label = "Add", small = true, enabled = draft.trim().isNotEmpty(), onClick = ::save)
            }
            Text(
                "Saves to $place.",
                style = TextStyle(fontSize = 11.sp),
                color = LocalTsColors.current.textSecondary,
            )
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
            TsSearchField(prompt = "Search notes", query = search, onQueryChange = { search = it }, modifier = Modifier.weight(1f))
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
            SectionLabel(if (showingArchive) "Archived notes" else "Notes", notes.size, Modifier.weight(1f))
            TsSecondaryButton(
                label = if (alphabetical) "Title A–Z" else "Newest first",
                small = true,
                onClick = { alphabetical = !alphabetical },
            )
            TsSecondaryButton(
                label = if (showingArchive) "Show notes" else "Show archive",
                small = true,
                enabled = archivedCount > 0 || showingArchive,
                onClick = { showingArchive = !showingArchive },
            )
        }
        if (error != null) Banner(error!!, BannerSeverity.DANGER)
        if (!loading && notes.isEmpty() && error == null) {
            EmptyState(
                Icons.AutoMirrored.Filled.Notes,
                if (search.isNotEmpty()) "No matching notes" else if (showingArchive) "Nothing archived" else "No notes yet",
                if (showingArchive) "Notes you put away in $place show up here."
                else "Anything worth remembering about $place. Type above and press return.",
                art = { EmptyArt(EmptyArtKind.Notes) },
            )
        }
        LazyColumn(verticalArrangement = Arrangement.spacedBy(Space.s)) {
            items(notes, key = { it.id }) { note ->
                val pending = note.id.startsWith("pending:")
                Column(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(cardRadiusDp))
                        .background(LocalTsColors.current.panel)
                        .clickable(enabled = !pending) { editing = note }
                        .padding(Space.m),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    Text(
                        note.title,
                        style = TextStyle(fontSize = 14.sp),
                        color = LocalTsColors.current.textPrimary,
                        maxLines = 4,
                    )
                    if (note.body.isNotBlank()) {
                        Text(
                            note.body,
                            style = TextStyle(fontSize = 12.sp),
                            color = LocalTsColors.current.textSecondary,
                            maxLines = 3,
                        )
                    }
                    if (note.createdAtMs > 0) {
                        RelativeTimeText(
                            note.createdAtMs,
                            style = TextStyle(fontSize = 11.sp),
                            color = LocalTsColors.current.textSecondary,
                        )
                    }
                    if (!pending) {
                        Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                            TextButton(onClick = { move(note, !showingArchive) }) {
                                Text(if (showingArchive) "Restore" else "Archive")
                            }
                            if (!showingArchive) {
                                TextButton(onClick = { convert(note) }) { Text("Make a task") }
                                TextButton(onClick = { editing = note }) { Text("Edit") }
                            }
                            TextButton(onClick = { pendingDelete = note }) { Text("Delete") }
                        }
                    }
                }
            }
        }
    }
    val doomed = pendingDelete
    if (doomed != null) {
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Delete this note?") },
            text = { Text("Archiving keeps it. Deleting does not.") },
            confirmButton = {
                TextButton(onClick = { pendingDelete = null; delete(doomed) }) { Text("Delete") }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) { Text("Keep it") }
            },
        )
    }
    val target = editing
    if (target != null) {
        NoteEditorDialog(
            note = target,
            onDismiss = { editing = null },
            onSave = { text -> editing = null; rename(target, text) },
        )
    }
}



@Composable
private fun NoteEditorDialog(note: NoteList.NoteCard, onDismiss: () -> Unit, onSave: (String) -> Unit) {
    var text by remember(note.id) { mutableStateOf(note.title) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Edit note") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                OutlinedTextField(text, { text = it }, modifier = Modifier.fillMaxWidth(), minLines = 3)
                Text("A note is its text, so this is the whole of it.")
            }
        },
        confirmButton = {
            TextButton(enabled = text.trim().isNotEmpty(), onClick = { onSave(text.trim()) }) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
