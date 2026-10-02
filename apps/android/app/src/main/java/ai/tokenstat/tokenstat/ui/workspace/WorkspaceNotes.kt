// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.localization.L10n

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
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import ai.tokenstat.tokenstat.ui.logic.NoteFormat
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
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsSearchField
import ai.tokenstat.tokenstat.ui.components.cardRadiusDp
import ai.tokenstat.tokenstat.ui.logic.NoteList
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import ai.tokenstat.tokenstat.ui.marks.EmptyArt
import ai.tokenstat.tokenstat.ui.marks.EmptyArtKind
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import kotlinx.coroutines.CancellationException
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
        revision = long("revision"),
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
        }.onFailure { error = TunnelCopy.display(it.message ?: L10n.text("android.workspacenotes.the_request_failed.db4fb447"), hostLabel) }
        loading = false
    }
    LaunchedEffect(workspace) { load() }

    val place = folderName.ifBlank { L10n.text("android.workspacenotes.this_folder.9d6325c8") }
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
                error = TunnelCopy.display(it.message ?: L10n.text("android.workspacenotes.the_request_failed.db4fb447"), hostLabel)
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
            }.onFailure { error = TunnelCopy.display(it.message ?: L10n.text("android.workspacenotes.the_request_failed.db4fb447"), hostLabel) }
        }
    }

    suspend fun updateNote(note: NoteList.NoteCard, title: String, body: String): Boolean {
        if (title.isEmpty()) return false
        if (title == note.title && body == note.body) return true
        return runCatching {
            editNote(note, title, body) { method, params ->
                model.workspaceSection(peer, method, params) as JsonObject
            }
        }.fold(onSuccess = { updated ->
            updated.toNoteCard()?.let { fresh -> cards = cards.map { if (it.id == fresh.id) fresh else it } }
            error = null
            true
        }, onFailure = {
            if (it is CancellationException) throw it
            error = TunnelCopy.display(it.message ?: L10n.text("android.workspacenotes.the_request_failed.db4fb447"), hostLabel)
            false
        })
    }

    suspend fun readNote(id: String): NoteList.NoteCard? {
        val fresh = (model.workspaceSection(peer, "todo.get", buildJsonObject { put("id", id) }) as? JsonObject)
            ?.toNoteCard()
        cards = if (fresh == null) cards.filterNot { it.id == id }
            else cards.map { if (it.id == id) fresh else it }
        return fresh
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
            }.onFailure { error = TunnelCopy.display(it.message ?: L10n.text("android.workspacenotes.the_request_failed.db4fb447"), hostLabel) }
        }
    }

    fun delete(note: NoteList.NoteCard) {
        scope.launch {
            runCatching {
                model.workspaceSection(peer, "todo.remove", buildJsonObject { put("id", note.id) })
            }.onSuccess {
                cards = cards.filter { it.id != note.id }
                error = null
            }.onFailure { error = TunnelCopy.display(it.message ?: L10n.text("android.workspacenotes.the_request_failed.db4fb447"), hostLabel) }
        }
    }

    Column(modifier, verticalArrangement = Arrangement.spacedBy(Space.s)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
            TsSearchField(prompt = if (showingArchive) L10n.text("android.workspacenotes.search_archived_notes.aa6a048e") else L10n.text("android.workspacenotes.search_notes.6e7a2179"),
                query = search, onQueryChange = { search = it }, modifier = Modifier.weight(1f))
            TsSecondaryButton(label = L10n.text("android.workspacenotes.new_note.76ea482f"), icon = ActionIcon.Create.vector, small = true,
                onClick = { showingArchive = false; showingComposer = true })
            Box {
                TsSecondaryButton(label = L10n.text("android.workspacenotes.view.dcc839a4"), icon = ActionIcon.More.vector, small = true,
                    onClick = { libraryMenu = true })
                DropdownMenu(expanded = libraryMenu, onDismissRequest = { libraryMenu = false }) {
                    DropdownMenuItem(text = { Text(if (alphabetical) L10n.text("android.workspacenotes.sort_newest_first.7b2f1373") else L10n.text("android.workspacenotes.sort_by_title.0cfdc1cd")) },
                        onClick = { alphabetical = !alphabetical; libraryMenu = false })
                    DropdownMenuItem(text = { Text(if (showingArchive) L10n.text("android.workspacenotes.show_notes.1415fb63") else L10n.text("android.workspacenotes.show_archive_0.6636e64b", "${archivedCount}")) },
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
                    placeholder = { Text(L10n.text("android.workspacenotes.something_worth_remembering.a56cd69e")) },
                    minLines = 2, maxLines = 5)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    Text(L10n.text("android.workspacenotes.saves_to_0.49357925", "${place}"), modifier = Modifier.weight(1f),
                        style = TextStyle(fontSize = 11.sp), color = LocalTsColors.current.textSecondary)
                    TsSecondaryButton(label = L10n.text("common.close"), icon = ActionIcon.Dismiss.vector, small = true,
                        onClick = { showingComposer = false })
                    TsAccentButton(label = L10n.text("common.add"), icon = ActionIcon.Create.vector, small = true,
                        enabled = draft.trim().isNotEmpty(), onClick = ::save)
                }
            }
        }
        SectionLabel(if (showingArchive) L10n.text("android.workspacenotes.archived_notes.27a341f0") else L10n.text("common.notes"), notes.size)
        if (error != null) Banner(error!!, BannerSeverity.DANGER)
        if (!loading && notes.isEmpty() && error == null) {
            EmptyState(
                Icons.AutoMirrored.Filled.Notes,
                if (search.isNotEmpty()) L10n.text("android.workspacenotes.no_matching_notes.5a859d10") else if (showingArchive) L10n.text("android.workspacenotes.nothing_archived.cd084fd7") else L10n.text("android.workspacenotes.no_notes_yet.a092ad6b"),
                if (showingArchive) L10n.text("android.workspacenotes.notes_you_put_away_in_0_show_up_here.bab677fb", "${place}")
                else L10n.text("android.workspacenotes.keep_anything_worth_remembering_about_0_ch.ca4055ff", "${place}"),
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
                                label = L10n.text("android.workspacenotes.actions.ff8059dc"),
                                icon = ActionIcon.More.vector,
                                small = true,
                                onClick = { menu = true },
                            )
                            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                                DropdownMenuItem(
                                    text = { Text(if (showingArchive) L10n.text("common.restore") else L10n.text("common.archive")) },
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
                                        text = { Text(L10n.text("android.workspacenotes.make_a_task.0cfbd102")) },
                                        leadingIcon = { Icon(ActionIcon.Move.vector, null) },
                                        onClick = { menu = false; convert(note) },
                                    )
                                    DropdownMenuItem(
                                        text = { Text(L10n.text("common.edit")) },
                                        leadingIcon = { Icon(ActionIcon.Edit.vector, null) },
                                        onClick = { menu = false; editing = note },
                                    )
                                }
                                HorizontalDivider()
                                DropdownMenuItem(
                                    text = { Text(L10n.text("common.delete"), color = LocalTsColors.current.danger) },
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
            title = { Text(L10n.text("android.workspacenotes.delete_this_note.f8069d7e")) },
            text = { Text(L10n.text("android.workspacenotes.archiving_keeps_it_deleting_does_not.55919870")) },
            confirmButton = {
                TextButton(onClick = { pendingDelete = null; delete(doomed) }) { Text(L10n.text("common.delete")) }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) { Text(L10n.text("android.workspacenotes.keep_it.fdce5da2")) }
            },
        )
    }
    val target = editing
    if (target != null) {
        NoteEditorDialog(
            note = target,
            onDismiss = { editing = null },
            error = error,
            onRead = { readNote(target.id) },
            onSave = { baseline, title, body ->
                val saved = updateNote(baseline, title, body)
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
    onRead: suspend () -> NoteList.NoteCard?,
    onSave: suspend (NoteList.NoteCard, String, String) -> Boolean,
) {
    // Restore the reviewed revision with the writing. A recreated Activity
    // must not silently rebase an old draft onto a newer host note.
    val baselineSaver = remember {
        listSaver<NoteList.NoteCard, Any>(
            save = { listOf(it.id, it.title, it.body, it.column, it.createdAtMs, it.revision ?: -1L) },
            restore = { NoteList.NoteCard(it[0] as String, it[1] as String, it[2] as String, it[3] as String,
                it[4] as Long, (it[5] as Long).takeIf { revision -> revision >= 0 }) },
        )
    }
    var baseline by rememberSaveable(note.id, stateSaver = baselineSaver) { mutableStateOf(note) }
    var changed by remember(note.id) { mutableStateOf<NoteList.NoteCard?>(null) }
    var missing by remember(note.id) { mutableStateOf(false) }
    var title by rememberSaveable(note.id) { mutableStateOf(note.title) }
    var body by rememberSaveable(note.id, stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue(note.body)) }
    var formatting by remember { mutableStateOf(false) }
    var preview by rememberSaveable(note.id) { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val colors = LocalTsColors.current
    Dialog(onDismissRequest = { if (!saving) onDismiss() },
        properties = DialogProperties(usePlatformDefaultWidth = false, dismissOnBackPress = !saving, dismissOnClickOutside = false)) {
        Column(Modifier.fillMaxSize().background(colors.background).systemBarsPadding().imePadding().padding(Space.m),
            verticalArrangement = Arrangement.spacedBy(Space.m)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                TextButton(enabled = !saving, onClick = onDismiss) { Text(L10n.text("common.cancel")) }
                Text(L10n.text("android.workspacenotes.note.d8da2c49"), style = TsType.chatBody)
                TextButton(enabled = !saving && !missing && changed == null && baseline.revision != null && title.trim().isNotEmpty(), onClick = {
                    saving = true
                    scope.launch {
                        try {
                            if (!onSave(baseline, title.trim(), body.text)) {
                                // A checked save keeps the writing in the editor. Read
                                // the competing version before offering an explicit choice.
                                try {
                                    val fresh = onRead()
                                    missing = fresh == null
                                    changed = fresh?.takeIf { it.revision != baseline.revision }
                                } catch (cancelled: CancellationException) { throw cancelled }
                                catch (_: Exception) { /* Keep the save failure and the draft. */ }
                            }
                        } finally { saving = false }
                    }
                }) { Text(if (saving) L10n.text("android.workspacenotes.saving.23e39291") else L10n.text("common.save")) }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                FilterChip(selected = !preview, onClick = { preview = false }, label = { Text(L10n.text("android.workspacenotes.write.3f00927a")) })
                FilterChip(selected = preview, onClick = { preview = true }, label = { Text(L10n.text("android.workspacenotes.preview.324b134f")) })
                if (!preview) Box {
                    TextButton(enabled = !saving, onClick = { formatting = true }) {
                        Icon(ActionIcon.Edit.vector, contentDescription = null)
                        Text(L10n.text("android.workspacenotes.format.2f343666"))
                    }
                    DropdownMenu(expanded = formatting, onDismissRequest = { formatting = false }) {
                        NoteFormat.entries.forEach { style ->
                            DropdownMenuItem(text = { Text(style.label) }, onClick = {
                                val edit = style.apply(body.text, body.selection.start, body.selection.end)
                                body = TextFieldValue(edit.text, TextRange(edit.start, edit.end))
                                formatting = false
                            })
                        }
                    }
                }
            }
            if (error != null) Text(error, color = colors.danger, style = TsType.caption)
            if (baseline.revision == null) Text(L10n.text("android.workspacenotes.revision_required"), color = colors.danger, style = TsType.caption)
            if (missing) Text(L10n.text("android.workspacenotes.deleted_while_editing"), color = colors.danger, style = TsType.caption)
            changed?.let { fresh ->
                TsCard {
                    Column(Modifier.padding(Space.s), verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                        Text(L10n.text("android.taskeditor.changed_on_the_computer.aefb92cf"), style = TsType.caption)
                        Text(fresh.title, maxLines = 2)
                        Text(fresh.body, maxLines = 4)
                        Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                            TextButton(enabled = !saving, onClick = {
                                baseline = fresh
                                title = fresh.title
                                body = TextFieldValue(fresh.body)
                                changed = null
                            }) { Text(L10n.text("android.taskeditor.use_computer_version.f0d6599f")) }
                            TextButton(enabled = !saving, onClick = { baseline = fresh; changed = null }) {
                                Text(L10n.text("android.taskeditor.keep_my_draft.cdb80bb9"))
                            }
                        }
                    }
                }
            }
            OutlinedTextField(title, { title = it }, enabled = !saving, label = { Text(L10n.text("android.workspacenotes.title.7e8cd205")) }, modifier = Modifier.fillMaxWidth())
            if (preview) {
                MarkdownText(body.text.ifBlank { L10n.text("android.workspacenotes.nothing_written_yet.4f01da04") }, TsType.chatBody, colors.textPrimary,
                    Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()))
            } else {
                OutlinedTextField(body, { body = it }, enabled = !saving, label = { Text(L10n.text("android.workspacenotes.note.d8da2c49")) },
                    modifier = Modifier.weight(1f).fillMaxWidth())
                Text(L10n.text("android.workspacenotes.markdown_supported_headings_lists_links_an.9e2568aa"), style = TsType.caption, color = colors.textSecondary)
            }
        }
    }
}
