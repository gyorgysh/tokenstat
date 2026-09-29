// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.FilterChip
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import ai.tokenstat.tokenstat.ui.components.TsType

import ai.tokenstat.tokenstat.ui.components.ActionIcon
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.ExperimentalLayoutApi

import ai.tokenstat.tokenstat.ui.chrome.TabBarChrome
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
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
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
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
    var draft by rememberSaveable(peer, workspace) { mutableStateOf("") }
    var showingComposer by rememberSaveable(peer, workspace) { mutableStateOf(false) }
    var libraryMenu by remember { mutableStateOf(false) }
    val draftFocus = remember { FocusRequester() }
    LaunchedEffect(showingComposer) { if (showingComposer) draftFocus.requestFocus() }
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

    suspend fun updateNote(note: NoteList.NoteCard, title: String, body: String): Boolean {
        if (title.isEmpty()) return false
        if (title == note.title && body == note.body) return true
        return runCatching {
            model.workspaceSection(peer, "todo.update", buildJsonObject {
                put("id", note.id)
                put("title", title)
                put("notes", body)
            }) as JsonObject
        }.fold(onSuccess = { updated ->
            updated.toNoteCard()?.let { fresh -> cards = cards.map { if (it.id == fresh.id) fresh else it } }
            error = null
            true
        }, onFailure = {
            error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel)
            false
        })
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
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
            TsSearchField(prompt = if (showingArchive) "Search archived notes" else "Search notes",
                query = search, onQueryChange = { search = it }, modifier = Modifier.weight(1f))
            TsSecondaryButton(label = "New note", icon = ActionIcon.Create.vector, small = true,
                onClick = { showingArchive = false; showingComposer = true })
            Box {
                TsSecondaryButton(label = "View", icon = ActionIcon.More.vector, small = true,
                    onClick = { libraryMenu = true })
                DropdownMenu(expanded = libraryMenu, onDismissRequest = { libraryMenu = false }) {
                    DropdownMenuItem(text = { Text(if (alphabetical) "Sort newest first" else "Sort by title") },
                        onClick = { alphabetical = !alphabetical; libraryMenu = false })
                    DropdownMenuItem(text = { Text(if (showingArchive) "Show notes" else "Show archive ($archivedCount)") },
                        onClick = { showingArchive = !showingArchive; showingComposer = false; libraryMenu = false })
                }
            }
        }
        if (showingComposer && !showingArchive) {
            Column(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(cardRadiusDp))
                    .background(LocalTsColors.current.panel).padding(Space.m),
                verticalArrangement = Arrangement.spacedBy(Space.xs),
            ) {
                OutlinedTextField(draft, { draft = it },
                    modifier = Modifier.fillMaxWidth().focusRequester(draftFocus),
                    placeholder = { Text("Something worth remembering") },
                    minLines = 2, maxLines = 5)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    Text("Saves to $place.", modifier = Modifier.weight(1f),
                        style = TextStyle(fontSize = 11.sp), color = LocalTsColors.current.textSecondary)
                    TsSecondaryButton(label = "Close", icon = ActionIcon.Dismiss.vector, small = true,
                        onClick = { showingComposer = false })
                    TsAccentButton(label = "Add", icon = ActionIcon.Create.vector, small = true,
                        enabled = draft.trim().isNotEmpty(), onClick = ::save)
                }
            }
        }
        SectionLabel(if (showingArchive) "Archived notes" else "Notes", notes.size)
        if (error != null) Banner(error!!, BannerSeverity.DANGER)
        if (!loading && notes.isEmpty() && error == null) {
            EmptyState(
                Icons.AutoMirrored.Filled.Notes,
                if (search.isNotEmpty()) "No matching notes" else if (showingArchive) "Nothing archived" else "No notes yet",
                if (showingArchive) "Notes you put away in $place show up here."
                else "Keep anything worth remembering about $place. Choose New note to start.",
                art = { EmptyArt(EmptyArtKind.Notes) },
            )
        }
        LazyColumn(contentPadding = PaddingValues(bottom = TabBarChrome.contentBottomInset), verticalArrangement = Arrangement.spacedBy(Space.s)) {
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
                        maxLines = 2,
                    )
                    if (note.body.isNotBlank()) {
                        Text(
                            note.body,
                            style = TextStyle(fontSize = 12.sp),
                            color = LocalTsColors.current.textSecondary,
                            maxLines = 2,
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
                        // One overflow, the way the SSH host row does it.
                        // Four bare text links read as a sentence that
                        // happened to be tappable and gave no sign which one
                        // was destructive; four buttons wrapped onto two
                        // lines and made every note twice as tall. A menu
                        // names each action with its glyph and costs one row.
                        var menu by remember(note.id) { mutableStateOf(false) }
                        Box {
                            TsSecondaryButton(
                                label = "Actions",
                                icon = ActionIcon.More.vector,
                                small = true,
                                onClick = { menu = true },
                            )
                            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                                DropdownMenuItem(
                                    text = { Text(if (showingArchive) "Restore" else "Archive") },
                                    leadingIcon = {
                                        Icon(
                                            if (showingArchive) ActionIcon.Restore.vector else ActionIcon.Archive.vector,
                                            null,
                                        )
                                    },
                                    onClick = { menu = false; move(note, !showingArchive) },
                                )
                                if (!showingArchive) {
                                    DropdownMenuItem(
                                        text = { Text("Make a task") },
                                        leadingIcon = { Icon(ActionIcon.Move.vector, null) },
                                        onClick = { menu = false; convert(note) },
                                    )
                                    DropdownMenuItem(
                                        text = { Text("Edit") },
                                        leadingIcon = { Icon(ActionIcon.Edit.vector, null) },
                                        onClick = { menu = false; editing = note },
                                    )
                                }
                                HorizontalDivider()
                                DropdownMenuItem(
                                    text = { Text("Delete", color = LocalTsColors.current.danger) },
                                    leadingIcon = {
                                        Icon(ActionIcon.Delete.vector, null, tint = LocalTsColors.current.danger)
                                    },
                                    onClick = { menu = false; pendingDelete = note },
                                )
                            }
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
            error = error,
            onSave = { title, body ->
                val saved = updateNote(target, title, body)
                if (saved) editing = null
                saved
            },
        )
    }
}



@Composable
private fun NoteEditorDialog(
    note: NoteList.NoteCard,
    onDismiss: () -> Unit,
    error: String?,
    onSave: suspend (String, String) -> Boolean,
) {
    var title by rememberSaveable(note.id) { mutableStateOf(note.title) }
    var body by rememberSaveable(note.id) { mutableStateOf(note.body) }
    var preview by rememberSaveable(note.id) { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val colors = LocalTsColors.current
    Dialog(onDismissRequest = { if (!saving) onDismiss() },
        properties = DialogProperties(usePlatformDefaultWidth = false, dismissOnBackPress = !saving, dismissOnClickOutside = false)) {
        Column(Modifier.fillMaxSize().background(colors.background).systemBarsPadding().imePadding().padding(Space.m),
            verticalArrangement = Arrangement.spacedBy(Space.m)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                TextButton(enabled = !saving, onClick = onDismiss) { Text("Cancel") }
                Text("Note", style = TsType.chatBody)
                TextButton(enabled = !saving && title.trim().isNotEmpty(), onClick = {
                    saving = true
                    scope.launch { try { onSave(title.trim(), body) } finally { saving = false } }
                }) { Text(if (saving) "Saving…" else "Save") }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                FilterChip(selected = !preview, onClick = { preview = false }, label = { Text("Write") })
                FilterChip(selected = preview, onClick = { preview = true }, label = { Text("Preview") })
            }
            if (error != null) Text(error, color = colors.danger, style = TsType.caption)
            OutlinedTextField(title, { title = it }, enabled = !saving, label = { Text("Title") }, modifier = Modifier.fillMaxWidth())
            if (preview) {
                MarkdownText(body.ifBlank { "Nothing written yet." }, TsType.chatBody, colors.textPrimary,
                    Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()))
            } else {
                OutlinedTextField(body, { body = it }, enabled = !saving, label = { Text("Note") },
                    modifier = Modifier.weight(1f).fillMaxWidth())
                Text("Markdown supported: headings, lists, links and code.", style = TsType.caption, color = colors.textSecondary)
            }
        }
    }
}
