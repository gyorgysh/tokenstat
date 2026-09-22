// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.editor

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.ChoiceChip
import ai.tokenstat.tokenstat.ui.components.FieldSaveBar
import ai.tokenstat.tokenstat.ui.components.FieldSaveState
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import ai.tokenstat.tokenstat.ui.theme.syntax
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

data class EditorKey(val peer: String, val workspace: String, val path: String)

data class EditorOpen(val path: String, val content: String? = null)

/// One file open in the editor. A document rather than scattered state,
/// so highlighting, the saved copy, change marks and the save cannot go
/// out of step. Port of `EditorDocument` plus `ClientEditorTab`.
class EditorTab(val key: EditorKey, content: String) {
    var text by mutableStateOf(content)
    var savedText by mutableStateOf(content)
    var spans by mutableStateOf<List<SyntaxSpan>>(emptyList())
    var rules by mutableStateOf(SyntaxRules.FALLBACK)
    var highlightNote by mutableStateOf<String?>(null)
    var spansVersion by mutableStateOf(0)
    var changedLines by mutableStateOf<Set<Int>>(emptySet())
    var saving by mutableStateOf(false)
    var error by mutableStateOf<String?>(null)
    var conflictHost by mutableStateOf<String?>(null)
    var savedTick by mutableStateOf(false)

    val isDirty: Boolean get() = text != savedText
    val name: String get() = key.path.substringAfterLast('/')

    fun updateText(next: String) {
        if (next == text) return
        text = next
        if (isDirty) savedTick = false
    }

    /// Re-read from disk landed, or a save completed.
    fun adopt(content: String) {
        text = content
        savedText = content
        savedTick = false
    }

    fun markSaved(content: String? = null) {
        // A save acknowledges the submitted version. Edits made while
        // that request was in flight must remain dirty.
        savedText = content ?: text
        if (!isDirty) savedTick = true
    }
}

/// Owned by the editor dialog, so layout changes preserve buffers. Port
/// of `ClientEditorStore`: replace a clean buffer with a fresh host read
/// (dirty and in-flight saves keep what the person is looking at), dirty
/// buffers need explicit discard, and an in-flight save cannot be closed.
class EditorStore {
    private val tabsList = mutableStateListOf<EditorTab>()
    private val selections = mutableStateMapOf<Pair<String, String>, EditorKey>()

    val tabs: SnapshotStateList<EditorTab> get() = tabsList

    fun tabsFor(peer: String, workspace: String): List<EditorTab> =
        tabsList.filter { it.key.peer == peer && it.key.workspace == workspace }

    fun selected(peer: String, workspace: String): EditorTab? {
        val key = selections[peer to workspace] ?: return null
        return tabsList.firstOrNull { it.key == key }
    }

    fun tab(key: EditorKey): EditorTab? = tabsList.firstOrNull { it.key == key }

    fun open(key: EditorKey, content: String) {
        if (tab(key) != null) {
            select(key)
            return
        }
        tabsList.add(EditorTab(key, content))
        select(key)
    }

    fun select(key: EditorKey) {
        selections[key.peer to key.workspace] = key
    }

    fun showFiles(peer: String, workspace: String) {
        selections.remove(peer to workspace)
    }

    /// Dirty buffers need explicit discard. An in-flight save cannot close.
    fun close(tab: EditorTab, discard: Boolean = false): Boolean {
        if (tab.saving || (!discard && tab.isDirty)) return false
        val wasSelected = selected(tab.key.peer, tab.key.workspace) == tab
        tabsList.remove(tab)
        if (wasSelected) {
            val next = tabsFor(tab.key.peer, tab.key.workspace).lastOrNull()
            if (next != null) select(next.key) else showFiles(tab.key.peer, tab.key.workspace)
        }
        return true
    }

    fun adoptSaved(key: EditorKey, content: String) {
        val tab = tab(key) ?: return open(key, content)
        if (tab.saving || tab.isDirty) {
            select(tab.key)
            return
        }
        tab.adopt(content)
        select(tab.key)
    }

    suspend fun save(model: AppViewModel, tab: EditorTab, hostLabel: String, onSavedFile: () -> Unit) {
        if (!tabsList.contains(tab) || tab.saving || !tab.isDirty || tab.conflictHost != null) return
        tab.saving = true
        tab.error = null
        try {
            // The host file may have moved since this buffer opened: another
            // window, the Mac, or a run writing output. Re-read before
            // writing so a stale draft cannot silently overwrite newer host
            // content.
            val host = runCatching {
                model.workspaceSection(tab.key.peer, "workspace.read", buildJsonObject {
                    put("id", tab.key.workspace)
                    put("path", tab.key.path)
                }) as JsonObject
            }.getOrNull()?.optStr("content")
            if (host == null) {
                tab.error = "Could not re-read this file on that computer, so the save waits. Your edits are kept."
                return
            }
            val draft = tab.text
            if (host != draft && host != tab.savedText) {
                tab.conflictHost = host
                return
            }
            if (host == draft) {
                // Already there: a lost acknowledgement or a matching remote
                // edit. Mark it saved without writing the same bytes again.
                tab.markSaved(draft)
                return
            }
            model.workspaceSection(tab.key.peer, "workspace.write", buildJsonObject {
                put("id", tab.key.workspace)
                put("path", tab.key.path)
                put("content", draft)
            })
            tab.markSaved(draft)
            onSavedFile()
        } catch (e: Exception) {
            tab.error = TunnelCopy.display(e.message ?: "The request failed.", hostLabel)
        } finally {
            tab.saving = false
        }
    }

    /// Choose a copy after a conflict. Reloading adopts the host and
    /// clears the draft; keeping writes the draft through explicitly.
    suspend fun resolveConflict(model: AppViewModel, tab: EditorTab, keepMine: Boolean, hostLabel: String, onSavedFile: () -> Unit) {
        if (!tabsList.contains(tab) || tab.saving) return
        val host = tab.conflictHost ?: return
        if (keepMine) {
            tab.conflictHost = null
            tab.error = null
            val sent = tab.text
            tab.saving = true
            try {
                model.workspaceSection(tab.key.peer, "workspace.write", buildJsonObject {
                    put("id", tab.key.workspace)
                    put("path", tab.key.path)
                    put("content", sent)
                })
                tab.markSaved(sent)
                onSavedFile()
            } catch (e: Exception) {
                tab.error = TunnelCopy.display(e.message ?: "The request failed.", hostLabel)
            } finally {
                tab.saving = false
            }
        } else {
            tab.adopt(host)
            tab.conflictHost = null
            tab.error = null
        }
    }
}

/// The tabbed code editor: syntax spans via `highlight` with the shared
/// palette, find/replace, gutter with change marks, save states with
/// read-before-write and conflict cards, and review-to-edit from diffs
/// (callers open a path straight into a tab).
///
/// Ports the iOS editor (`IOSCodeTextView`, `EditorDocument`,
/// `ClientEditorStore`) and the `ClientDiffView` review-to-edit flow.
@Composable
fun EditorDialog(
    model: AppViewModel,
    peer: String,
    workspace: String,
    folderName: String,
    hostLabel: String,
    initial: List<EditorOpen>,
    onSavedFile: () -> Unit = {},
    onDismiss: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val store = remember { EditorStore() }
    var loading by remember { mutableStateOf(initial.any { it.content == null }) }
    var loadError by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(peer, workspace) {
        initial.forEach { open ->
            val content = open.content ?: runCatching {
                model.workspaceSection(peer, "workspace.read", buildJsonObject {
                    put("id", workspace)
                    put("path", open.path)
                }) as JsonObject
            }.getOrNull()?.optStr("content")
            if (content != null) {
                store.adoptSaved(EditorKey(peer, workspace, open.path), content)
            } else {
                loadError = TunnelCopy.display("The request failed.", hostLabel)
            }
        }
        loading = false
    }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(Modifier.fillMaxSize().padding(Space.m)) {
            val tabs = store.tabsFor(peer, workspace)
            val selected = store.selected(peer, workspace)
            EditorTabStrip(
                tabs = tabs,
                selected = selected,
                onSelect = { store.select(it.key) },
                onClose = { store.close(it) },
                onFiles = onDismiss,
            )
            if (loadError != null) Banner(loadError!!, BannerSeverity.DANGER)
            if (loading) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    CircularProgressIndicator()
                    Text("Opening file", color = LocalTsColors.current.textSecondary)
                }
            } else if (selected != null) {
                EditorPane(
                    model = model,
                    hostLabel = hostLabel,
                    folderName = folderName,
                    store = store,
                    tab = selected,
                    onSavedFile = onSavedFile,
                )
            } else {
                Text(
                    "No file open. Open one from the file list or a diff.",
                    style = TsType.caption,
                    color = LocalTsColors.current.textSecondary,
                )
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun EditorTabStrip(
    tabs: List<EditorTab>,
    selected: EditorTab?,
    onSelect: (EditorTab) -> Unit,
    onClose: (EditorTab) -> Boolean,
    onFiles: () -> Unit,
) {
    var confirming: EditorTab? by remember { mutableStateOf(null) }
    FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
        TsSecondaryButton(label = "Files", small = true, onClick = onFiles)
        tabs.forEach { tab ->
            ChoiceChip(
                (if (tab.isDirty) "· " else "") + tab.name.ifBlank { tab.key.path },
                selected == tab,
                { onSelect(tab) },
            )
            TextButton(onClick = {
                if (!onClose(tab)) confirming = tab
            }) { Text("×", color = LocalTsColors.current.textSecondary) }
        }
    }
    val closing = confirming
    if (closing != null) {
        AlertDialog(
            onDismissRequest = { confirming = null },
            title = { Text("Discard changes?") },
            text = { Text("${closing.key.path} has edits that are not saved on that computer.") },
            confirmButton = {
                TextButton(onClick = {
                    onClose(closing)
                    confirming = null
                }) { Text("Discard") }
            },
            dismissButton = { TextButton(onClick = { confirming = null }) { Text("Keep editing") } },
        )
    }
}

@Composable
private fun EditorPane(
    model: AppViewModel,
    hostLabel: String,
    folderName: String,
    store: EditorStore,
    tab: EditorTab,
    onSavedFile: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val colors = LocalTsColors.current
    val find = remember(tab.key) { EditorFind() }
    var showFind by remember(tab.key) { mutableStateOf(false) }
    var field by remember(tab.key) { mutableStateOf(TextFieldValue(tab.text)) }
    // Outside edits (find replace, adopt, conflict reload) flow back into
    // the field, keeping the cursor when the text still contains it.
    fun syncField(next: String, cursor: Int? = null) {
        val selection = when {
            cursor != null -> TextRange(cursor.coerceIn(0, next.length))
            field.selection.start <= next.length -> field.selection
            else -> TextRange(next.length)
        }
        field = TextFieldValue(next, selection)
    }

    // Colour the buffer once it stops changing. Debounced: highlighting
    // is a parse of the whole file plus a tunnel round trip, and nobody
    // sees the difference between now and a breath from now. The buffer
    // may have moved on while this was in flight; spans measured against
    // older text colour the wrong ranges, so they are dropped.
    LaunchedEffect(tab.text) {
        delay(300)
        val source = tab.text
        runCatching {
            model.workspaceSection(tab.key.peer, "highlight", buildJsonObject {
                put("path", tab.key.path)
                put("text", source)
            }) as JsonObject
        }.onSuccess { element ->
            if (source != tab.text) return@LaunchedEffect
            val result = Highlighting.parse(element)
            tab.spans = result.spans
            tab.rules = result.rules
            tab.highlightNote = result.note
            tab.spansVersion += 1
        }.onFailure {
            if (source != tab.text) return@LaunchedEffect
            // Colour is not worth an error banner. The file is still
            // editable and still saveable without it.
            tab.spans = emptyList()
            tab.highlightNote = TunnelCopy.display(it.message ?: "The request failed.", hostLabel)
            tab.spansVersion += 1
        }
    }
    LaunchedEffect(tab.text) { find.refresh(tab.text) }

    // Change marks come from the same `workspace.diff` the Changes panel
    // parsed, so the two cannot disagree. Reloads when the file opens and
    // whenever the dirty state settles after a save.
    suspend fun reloadMarks() {
        val diff = runCatching {
            model.workspaceSection(tab.key.peer, "workspace.diff", buildJsonObject {
                put("id", tab.key.workspace)
                put("path", tab.key.path)
            }) as JsonObject
        }.getOrNull()
        tab.changedLines = changedLinesFromDiff(diff)
    }
    LaunchedEffect(tab.key) { reloadMarks() }
    LaunchedEffect(tab.isDirty) { if (!tab.isDirty) reloadMarks() }

    val annotated = remember(tab.text, tab.spans, tab.spansVersion, find.query, find.matchCount) {
        buildAnnotated(tab.text, tab.spans, find, colors)
    }
    val starts = remember(tab.text) { EditorGutterMap.lineStarts(tab.text) }
    val scroll = rememberScrollState()
    val fileName = tab.name.ifBlank { tab.key.path }

    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(Space.s)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(fileName, style = TsType.mono(13), color = colors.textPrimary, maxLines = 1)
                Text(
                    folderName.ifBlank { "Back" },
                    style = TsType.caption,
                    color = colors.accent,
                    maxLines = 1,
                )
            }
            if (tab.saving) {
                CircularProgressIndicator()
            } else {
                Text(
                    when {
                        tab.error != null -> "Not saved"
                        tab.savedTick -> "Saved"
                        tab.isDirty -> "Unsaved"
                        else -> ""
                    },
                    style = TsType.caption,
                    color = when {
                        tab.error != null -> colors.danger
                        tab.savedTick -> colors.success
                        tab.isDirty -> colors.warning
                        else -> colors.textSecondary
                    },
                )
            }
            IconButton(onClick = { showFind = !showFind }) {
                Icon(ActionIcon.Search.vector, "Find in file", tint = colors.controlGlyph)
            }
        }
        if (tab.error != null) Banner(tab.error!!, BannerSeverity.DANGER)
        val conflict = tab.conflictHost
        if (conflict != null) {
            EditorConflictCard(
                mineLines = tab.text.split('\n').size,
                hostLines = conflict.split('\n').size,
                firstDifference = firstDifference(tab.text, conflict),
                onReload = { scope.launch { store.resolveConflict(model, tab, keepMine = false, hostLabel, onSavedFile) } },
                onKeep = {
                    tab.conflictHost = null
                    tab.error = null
                    scope.launch { store.save(model, tab, hostLabel, onSavedFile) }
                },
            )
        }
        if (showFind) {
            androidx.compose.runtime.key(tab.key) {
                EditorFindBar(
                    find = find,
                    onNavigate = { range ->
                        range?.let { syncField(tab.text, it.first) }
                    },
                    onReplaceCurrent = {
                        find.replaceCurrent(tab.text)?.let { next ->
                            val range = find.current
                            tab.updateText(next)
                            find.refresh(next)
                            syncField(next, range?.let { it.first + find.replaceText.length })
                        }
                    },
                    onReplaceAll = {
                        find.replaceAll(tab.text)?.let { next ->
                            tab.updateText(next)
                            find.refresh(next)
                            syncField(next, 0)
                        }
                    },
                    onClose = {
                        showFind = false
                        find.showing = false
                        find.clear()
                    },
                )
            }
        }
        // One shared scroll for gutter and buffer, so the numbers and the
        // change marks ride with the text. Both sides size to content, and
        // only paragraph starts are numbered: wrapped lines share their
        // paragraph's row, like the iOS gutter.
        Row(
            Modifier
                .weight(1f)
                .verticalScroll(scroll),
        ) {
            EditorGutter(
                starts = starts,
                changedLines = tab.changedLines,
            )
            BasicTextField(
                value = TextFieldValue(annotated, field.selection, field.composition),
                onValueChange = { next ->
                    var text = next.text
                    // Tab inserts the language indent, not a raw tab.
                    if (text.contains('\t') && !tab.text.contains('\t')) {
                        text = text.replace("\t", tab.rules.indentUnit)
                    }
                    tab.updateText(text)
                    field = next.copy(text = text)
                },
                modifier = Modifier.weight(1f),
                textStyle = TsType.mono(13).copy(color = colors.textPrimary, lineHeight = 20.sp),
                cursorBrush = SolidColor(colors.accent),
            )
        }
        if (tab.highlightNote != null) {
            Text(tab.highlightNote!!, style = TsType.caption, color = colors.textSecondary)
        }
        val saveState = when {
            tab.saving -> FieldSaveState.Saving
            tab.error != null -> FieldSaveState.Failed
            tab.isDirty -> FieldSaveState.Dirty
            tab.savedTick -> FieldSaveState.Saved
            else -> FieldSaveState.Idle
        }
        FieldSaveBar(
            state = saveState,
            onSave = { scope.launch { store.save(model, tab, hostLabel, onSavedFile); syncField(tab.text) } },
            onCancel = {
                tab.adopt(tab.savedText)
                find.refresh(tab.text)
                syncField(tab.text)
            },
            saveTitle = "Save",
            canSave = tab.isDirty && !tab.saving && tab.conflictHost == null,
        )
    }
}

private fun buildAnnotated(
    text: String,
    spans: List<SyntaxSpan>,
    find: EditorFind,
    colors: ai.tokenstat.tokenstat.ui.theme.TsColors,
): AnnotatedString {
    return buildAnnotatedString {
        append(text)
        spans.forEach { span ->
            val clamped = span.clamped(text.length) ?: return@forEach
            addStyle(SpanStyle(color = colors.syntax(clamped.kind)), clamped.start, clamped.start + clamped.length)
        }
        // Match tint sits over syntax colour: what is found is what stands out.
        find.snapshot().forEach { range ->
            val from = range.first.coerceIn(0, text.length)
            val to = (range.last + 1).coerceIn(0, text.length)
            if (to <= from) return@forEach
            val current = find.current == range
            addStyle(
                SpanStyle(background = if (current) FIND_CURRENT else FIND_MATCH),
                from,
                to,
            )
        }
    }
}

/// The in-app find bar: query, match count, previous/next, replace.
/// Port of `EditorFindBar`: the query gets the full first row, the
/// controls a second row of full-size targets, because four glyph buttons
/// beside the field do not fit a phone portrait.
@Composable
private fun EditorFindBar(
    find: EditorFind,
    onNavigate: (IntRange?) -> Unit,
    onReplaceCurrent: () -> Unit,
    onReplaceAll: () -> Unit,
    onClose: () -> Unit,
) {
    var query by remember { mutableStateOf(find.query) }
    var replace by remember { mutableStateOf(find.replaceText) }
    var replacing by remember { mutableStateOf(find.replacing) }
    val colors = LocalTsColors.current
    TsCard {
        Column(Modifier.padding(Space.s), verticalArrangement = Arrangement.spacedBy(Space.s)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                OutlinedTextField(
                    query,
                    {
                        query = it
                        find.query = it
                    },
                    modifier = Modifier.weight(1f),
                    label = { Text("Find in file") },
                    singleLine = true,
                )
                find.countLabel?.let {
                    Text(it, style = TsType.caption, color = colors.textSecondary)
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                TsSecondaryButton(label = "Previous", small = true, enabled = find.canNavigate, onClick = {
                    find.goPrevious()
                    onNavigate(find.current)
                })
                TsSecondaryButton(label = "Next", small = true, enabled = find.canNavigate, onClick = {
                    find.goNext()
                    onNavigate(find.current)
                })
                TsSecondaryButton(
                    label = if (replacing) "Hide replace" else "Replace",
                    small = true,
                    onClick = {
                        replacing = !replacing
                        find.replacing = replacing
                    },
                )
                Spacer(Modifier.weight(1f))
                TextButton(onClick = onClose) { Text("Close") }
            }
            if (replacing) {
                OutlinedTextField(
                    replace,
                    {
                        replace = it
                        find.replaceText = it
                    },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text("Replace with") },
                    singleLine = true,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    TsSecondaryButton(label = "Replace", small = true, enabled = find.canReplace, onClick = onReplaceCurrent)
                    TsSecondaryButton(label = "Replace all", small = true, enabled = find.canReplace, onClick = onReplaceAll)
                    Text(
                        "Replace all is one undo, in this file only.",
                        style = TsType.caption,
                        color = colors.textSecondary,
                    )
                }
            }
        }
    }
}

/// The host file moved while the draft was dirty. Saving stays off until
/// the person chooses a copy. Port of `EditorConflictCard`.
@Composable
private fun EditorConflictCard(
    mineLines: Int,
    hostLines: Int,
    firstDifference: Int?,
    onReload: () -> Unit,
    onKeep: () -> Unit,
) {
    val colors = LocalTsColors.current
    TsCard {
        Column(Modifier.padding(Space.m), verticalArrangement = Arrangement.spacedBy(Space.s)) {
            Text(
                "This file changed on that computer.",
                style = TsType.body.copy(fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
            )
            Text(
                buildString {
                    append("Yours has $mineLines lines, that computer has $hostLines. Saving is off until you choose.")
                    if (firstDifference != null) append(" First difference: line $firstDifference.")
                },
                style = TsType.caption,
                color = colors.textSecondary,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                TsSecondaryButton(label = "Reload computer", small = true, onClick = onReload)
                TsAccentButton(label = "Keep my draft", small = true, onClick = onKeep)
            }
        }
    }
}

/// Line numbers with change marks. Added lines carry the diff colour in
/// the marker lane, so the gutter and the Changes panel cannot disagree.
@Composable
private fun EditorGutter(
    starts: List<Int>,
    changedLines: Set<Int>,
) {
    val colors = LocalTsColors.current
    Column(
        Modifier.padding(end = Space.xs),
        verticalArrangement = Arrangement.Top,
    ) {
        starts.forEachIndexed { index, _ ->
            val line = index + 1
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier
                        .width(3.dp)
                        .height(20.sp.value.dp)
                        .background(if (changedLines.contains(line)) colors.diffAdded else androidx.compose.ui.graphics.Color.Transparent),
                )
                Spacer(Modifier.width(4.dp))
                Text(
                    line.toString(),
                    style = TsType.mono(11).copy(lineHeight = 20.sp),
                    color = colors.textTertiary,
                )
            }
        }
    }
}

private val FIND_MATCH = androidx.compose.ui.graphics.Color(0xFF8B5CF6).copy(alpha = 0.25f)
private val FIND_CURRENT = androidx.compose.ui.graphics.Color(0xFF8B5CF6).copy(alpha = 0.45f)
