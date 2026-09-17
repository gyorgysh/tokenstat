// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.tasks

import ai.tokenstat.tokenstat.ui.chrome.OwnSectionHeader

import androidx.compose.foundation.clickable

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.ChoiceChip
import ai.tokenstat.tokenstat.ui.components.EmptyState
import ai.tokenstat.tokenstat.ui.components.SectionLabel
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsSearchField
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.logic.HostContracts
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import ai.tokenstat.tokenstat.ui.marks.EmptyArt
import ai.tokenstat.tokenstat.ui.marks.EmptyArtKind
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

private val BOARD_COLUMNS = listOf(
    Triple("backlog", "To Do", "backlog"),
    Triple("doing", "Doing", "doing"),
    Triple("done", "Done", "done"),
)

/// The full task board behind the workspace Tasks tab: compact list,
/// explicit Move, detail editor, archive/restore/delete, agent plus
/// attention filters plus search, and run with receipts.
///
/// Ports `ClientTaskBoard` (phone stacked columns: the side-by-side board
/// is the wide presentation). Drag reorder becomes explicit Move
/// earlier/later, which is the same `todo.edit` order write.
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun TaskBoardDialog(
    model: AppViewModel,
    peer: String,
    hostLabel: String,
    protocol: Long?,
    fixedFolder: String?,
    folderName: String,
    onOpenTerminal: (String) -> Unit,
    onOpenSection: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        TaskBoardScreen(
            model = model,
            peer = peer,
            hostLabel = hostLabel,
            protocol = protocol,
            fixedFolder = fixedFolder,
            folderName = folderName,
            onOpenTerminal = onOpenTerminal,
            onOpenSection = onOpenSection,
            onBack = onDismiss,
        )
    }
}

/// The task board as a full page on the app background. Creation, editing
/// and run/result are full pages too, pushed over the board like the Apple
/// client's full-screen covers.
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun TaskBoardScreen(
    model: AppViewModel,
    peer: String,
    hostLabel: String,
    protocol: Long?,
    fixedFolder: String?,
    folderName: String,
    onOpenTerminal: (String) -> Unit,
    onOpenSection: (String) -> Unit,
    onBack: () -> Unit,
) {
    // The board has its own header, its own back and its own add. Two
    // headers with two back arrows is what stacking them looked like.
    OwnSectionHeader()
    val scope = rememberCoroutineScope()
    val canEdit = HostContracts.supportsTaskEditing(protocol)
    val canDelete = HostContracts.supportsTaskDeletion(protocol)
    var cards by remember { mutableStateOf<List<TaskCard>>(emptyList()) }
    var folders by remember { mutableStateOf<List<FolderRef>>(emptyList()) }
    var backends by remember { mutableStateOf<List<BackendRef>>(emptyList()) }
    var loaded by remember { mutableStateOf(false) }
    var loading by remember { mutableStateOf(true) }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var notice by remember { mutableStateOf<String?>(null) }
    var filter by remember(fixedFolder) {
        mutableStateOf(
            TaskBoardFilter(
                folder = fixedFolder?.let(TaskBoardFolder::Folder) ?: TaskBoardFolder.All,
            ),
        )
    }
    var showFilters by remember { mutableStateOf(false) }
    var composing by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<TaskCard?>(null) }
    var deleting by remember { mutableStateOf<TaskCard?>(null) }
    var viewingRun by remember { mutableStateOf<Pair<String, String>?>(null) }
    var queueBudget by remember { mutableStateOf(10_800L) }
    var generation by remember { mutableStateOf(0) }

    suspend fun load(includeOptions: Boolean = true) {
        loading = true
        val request = ++generation
        runCatching {
            model.workspaceSection(peer, "todo.list", buildJsonObject { put("includeArchived", true) })
        }.onSuccess { element ->
            if (request != generation) return
            cards = TaskCard.parseList(element)
            loaded = true
            error = null
        }.onFailure {
            if (request != generation) return
            error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel)
        }
        if (includeOptions) {
            runCatching { model.workspaceSection(peer, "workspace.list", buildJsonObject {}) }
                .onSuccess { element ->
                    if (request != generation) return
                    folders = ((element as? kotlinx.serialization.json.JsonArray)
                        ?.filterIsInstance<JsonObject>() ?: emptyList()).map(FolderRef::parse)
                }
            runCatching { model.workspaceSection(peer, "automation.backends", buildJsonObject {}) }
                .onSuccess { element ->
                    if (request != generation) return
                    backends = ((element as? kotlinx.serialization.json.JsonArray)
                        ?.filterIsInstance<JsonObject>() ?: emptyList()).map(BackendRef::parse)
                }
            runCatching { model.workspaceSection(peer, "automation.queue", buildJsonObject {}) }
                .onSuccess { element ->
                    if (request != generation) return
                    (element as? JsonObject)?.optLong("defaultBudgetSeconds")?.let { queueBudget = it }
                }
        }
        if (request == generation) loading = false
    }

    fun showNotice(text: String) {
        notice = text
    }

    suspend fun move(card: TaskCard, column: String, before: String? = null, atEnd: Boolean = false) {
        if (working || !canEdit) return
        if (!listOf("backlog", "doing", "done", "archive").contains(column)) return
        val revision = card.revision
        if (revision == null) {
            error = "Reload the board before moving this task."
            return
        }
        working = true
        notice = null
        try {
            val order: Long? = when {
                before != null -> {
                    val destination = cards.filter { it.column == column && it.id != card.id }.sortedBy { it.order }
                    val index = destination.indexOfFirst { it.id == before }
                    if (index < 0) null else index.toLong()
                }
                atEnd -> cards.count { it.column == column && it.id != card.id }.toLong()
                else -> null
            }
            if (before != null && order == null) return
            model.workspaceSection(peer, "todo.edit", buildJsonObject {
                put("id", card.id)
                put("expectedRevision", revision)
                put("column", column)
                if (order != null) put("order", order)
            })
            if (order != null) filter = filter.copy(newestFirst = false)
            showNotice(if (column == "archive") "Task archived" else "Task moved")
            error = null
            load(includeOptions = false)
        } catch (e: Exception) {
            error = "The move was not confirmed. Reload the board before trying again. ${TunnelCopy.display(e.message ?: "", hostLabel)}"
        } finally {
            working = false
        }
    }

    suspend fun delete(card: TaskCard) {
        if (working || !canDelete) return
        val revision = card.revision
        if (revision == null) {
            error = "Reload the board before deleting this task."
            return
        }
        working = true
        try {
            model.workspaceSection(peer, "todo.delete", buildJsonObject {
                put("id", card.id)
                put("expectedRevision", revision)
            })
            cards = cards.filter { it.id != card.id }
            deleting = null
            showNotice("Task deleted")
            error = null
        } catch (e: Exception) {
            error = "The deletion was not confirmed. Reload the board to check the task. ${TunnelCopy.display(e.message ?: "", hostLabel)}"
        } finally {
            working = false
        }
    }

    LaunchedEffect(peer) { load() }
    val anyRunning = cards.any { it.delegate?.isRunning == true }
    LaunchedEffect(anyRunning, peer) {
        if (!anyRunning) return@LaunchedEffect
        while (true) {
            delay(3_000)
            if (!working && !loading) load(includeOptions = false)
        }
    }

    val visible = remember(cards, filter) { filter.visible(cards) }
    val agentIds = remember(cards, backends, filter) {
        (cards.map { it.backend } + filter.backend).filter { it.isNotEmpty() }.toSet() + backends.map { it.id }
    }.sorted()

    BackHandler {
        when {
            composing -> composing = false
            editing != null -> editing = null
            viewingRun != null -> viewingRun = null
            deleting != null -> deleting = null
            else -> onBack()
        }
    }
    val editingCard = editing
    val run = viewingRun
    when {
        composing -> TaskCreateScreen(
            model = model,
            peer = peer,
            hostLabel = hostLabel,
            protocol = protocol,
            initialFolder = when (val folder = filter.folder) {
                is TaskBoardFolder.Folder -> folder.id
                else -> fixedFolder ?: ""
            },
            defaultBudget = queueBudget,
            backends = backends,
            folders = folders,
            onCreated = { scope.launch { load(includeOptions = false) } },
            onBack = { composing = false },
        )
        editingCard != null -> TaskEditorScreen(
            model = model,
            peer = peer,
            hostLabel = hostLabel,
            protocol = protocol,
            cardId = editingCard.id,
            backends = backends,
            folders = folders,
            onViewRun = { runID, workspaceID -> viewingRun = runID to workspaceID },
            onOpenTerminal = onOpenTerminal,
            onSaved = { scope.launch { load(includeOptions = false) } },
            onBack = { editing = null },
        )
        run != null -> TaskRunScreen(
            model = model,
            peer = peer,
            hostLabel = hostLabel,
            runID = run.first,
            workspaceID = run.second,
            folderName = folders.firstOrNull { it.id == run.second }?.name ?: folderName,
            onOpenTerminal = onOpenTerminal,
            onOpenSection = { onOpenSection(it); viewingRun = null },
            onBack = { viewingRun = null },
        )
        else -> Column(
            Modifier
                .fillMaxSize()
                .background(LocalTsColors.current.background)
                .padding(Space.m),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onBack) {
                    Icon(ActionIcon.Back.vector, "Back", tint = LocalTsColors.current.controlGlyph)
                }
                Column(Modifier.weight(1f)) {
                    Text(
                        if (fixedFolder == null) "All tasks" else "Tasks",
                        style = TsType.cardTitle,
                        color = LocalTsColors.current.textPrimary,
                    )
                    Text(
                        hostLabel,
                        style = TsType.caption,
                        color = LocalTsColors.current.textSecondary,
                    )
                }
                IconButton(onClick = { composing = true }, enabled = !composing && editing == null) {
                    Icon(ActionIcon.Create.vector, "New task", tint = LocalTsColors.current.accent)
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                TsSecondaryButton(
                    label = "Filters",
                    icon = ActionIcon.Filter.vector,
                    small = true,
                    onClick = { showFilters = !showFilters },
                )
                TsSecondaryButton(
                    label = if (filter.archived) "Open tasks" else "Archive",
                    icon = if (filter.archived) ActionIcon.Restore.vector else ActionIcon.Archive.vector,
                    small = true,
                    onClick = { filter = filter.copy(archived = !filter.archived) },
                )
            }
            Spacer(Modifier.padding(top = Space.s))
            TsSearchField(
                prompt = "Search tasks",
                query = filter.query,
                onQueryChange = { filter = filter.copy(query = it) },
            )
            if (showFilters) {
                Spacer(Modifier.padding(top = Space.s))
                if (fixedFolder == null) {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                        ChoiceChip("All folders", filter.folder is TaskBoardFolder.All, { filter = filter.copy(folder = TaskBoardFolder.All) })
                        ChoiceChip("Uncategorized", filter.folder is TaskBoardFolder.Uncategorized, { filter = filter.copy(folder = TaskBoardFolder.Uncategorized) })
                        folders.forEach { folder ->
                            ChoiceChip(folder.name.ifBlank { folder.id }, filter.folder == TaskBoardFolder.Folder(folder.id), { filter = filter.copy(folder = TaskBoardFolder.Folder(folder.id)) })
                        }
                    }
                }
                FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                    ChoiceChip("All agents", filter.backend.isEmpty(), { filter = filter.copy(backend = "") })
                    agentIds.forEach { id ->
                        ChoiceChip(backends.firstOrNull { it.id == id }?.label ?: id, filter.backend == id, { filter = filter.copy(backend = id) })
                    }
                }
                FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                    TaskBoardAttention.entries.forEach { attention ->
                        ChoiceChip(attention.label, filter.attention == attention, { filter = filter.copy(attention = attention) })
                    }
                    ChoiceChip("Board order", !filter.newestFirst, { filter = filter.copy(newestFirst = false) })
                    ChoiceChip("Newest first", filter.newestFirst, { filter = filter.copy(newestFirst = true) })
                }
            }
            val summary = remember(filter, folders, backends, fixedFolder) {
                buildList {
                    if (fixedFolder == null) {
                        when (val folder = filter.folder) {
                            is TaskBoardFolder.Folder -> add(folders.firstOrNull { it.id == folder.id }?.name ?: "Unavailable folder")
                            is TaskBoardFolder.Uncategorized -> add("Uncategorized")
                            is TaskBoardFolder.All -> Unit
                        }
                    }
                    if (filter.backend.isNotEmpty()) add(backends.firstOrNull { it.id == filter.backend }?.label ?: filter.backend)
                    if (filter.attention != TaskBoardAttention.ALL) add(filter.attention.label)
                    if (filter.newestFirst) add("Newest first")
                }.joinToString(" · ")
            }
            if (summary.isNotEmpty()) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(summary, style = TsType.caption, color = LocalTsColors.current.textSecondary, modifier = Modifier.weight(1f))
                    TextButton(onClick = {
                        filter = filter.copy(
                            folder = fixedFolder?.let(TaskBoardFolder::Folder) ?: TaskBoardFolder.All,
                            backend = "",
                            attention = TaskBoardAttention.ALL,
                            newestFirst = false,
                        )
                    }) { Text("Clear filters") }
                }
            }
            if (error != null) {
                Banner(error!!, BannerSeverity.DANGER)
                TsSecondaryButton(label = "Reload", small = true, onClick = { scope.launch { load() } })
            }
            if (!canEdit) {
                Text(
                    "Update $hostLabel's tokenstat to use all task editing and board actions.",
                    style = TsType.caption,
                    color = LocalTsColors.current.textSecondary,
                )
            }
            if (notice != null) {
                Text(notice!!, style = TsType.caption, color = LocalTsColors.current.textSecondary)
            }
            if (loading && !loaded) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    CircularProgressIndicator()
                    Text("Loading tasks", color = LocalTsColors.current.textSecondary)
                }
            }
            if (loaded && visible.isEmpty()) {
                EmptyState(
                    ActionIcon.Create.vector,
                    if (filter.archived) "No archived tasks" else "No tasks here",
                    "Create a task or adjust the filters to see more work.",
                    art = { EmptyArt(EmptyArtKind.Tasks) },
                )
            }
            PullToRefreshBox(isRefreshing = loading && loaded, onRefresh = { scope.launch { load() } }, modifier = Modifier.weight(1f)) {
                LazyColumn(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(Space.s)) {
                    val columns = if (filter.archived) listOf(Triple("archive", "Archive", "archive")) else BOARD_COLUMNS
                    columns.forEach { (id, title, _) ->
                        item(key = "header-$id") {
                            val count = visible.count { it.column == id }
                            SectionLabel(title, count)
                        }
                        val columnCards = visible.filter { it.column == id }
                        if (columnCards.isEmpty()) {
                            item(key = "empty-$id") {
                                Text("No tasks", style = TsType.caption, color = LocalTsColors.current.textSecondary)
                            }
                        }
                        items(columnCards, key = { "task-${it.id}" }) { card ->
                            TaskRow(
                                card = card,
                                showFolder = fixedFolder == null,
                                folderName = folders.firstOrNull { it.id == card.workspaceID }?.name
                                    ?: if (card.workspaceID.isEmpty()) "Uncategorized" else "Unavailable folder",
                                backendLabel = backends.firstOrNull { it.id == card.backend }?.label ?: card.backend,
                                working = working,
                                canEdit = canEdit,
                                canDelete = canDelete,
                                newestFirst = filter.newestFirst,
                                visibleInColumn = columnCards,
                                onEdit = { editing = card },
                                onMove = { column, before, atEnd -> scope.launch { move(card, column, before, atEnd) } },
                                onArchive = { scope.launch { move(card, "archive") } },
                                onRestore = { scope.launch { move(card, "backlog") } },
                                onDelete = { deleting = card },
                            )
                        }
                    }
                }
            }
        }
    }
    val deletingCard = deleting
    if (deletingCard != null) {
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text("Delete task?") },
            text = { Text("Delete \"${deletingCard.title}\"? This removes the task from this computer's board.") },
            confirmButton = {
                Button(onClick = { scope.launch { delete(deletingCard) } }) { Text("Delete task") }
            },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun TaskRow(
    card: TaskCard,
    showFolder: Boolean,
    folderName: String,
    backendLabel: String,
    working: Boolean,
    canEdit: Boolean,
    canDelete: Boolean,
    newestFirst: Boolean,
    visibleInColumn: List<TaskCard>,
    onEdit: () -> Unit,
    onMove: (column: String, before: String?, atEnd: Boolean) -> Unit,
    onArchive: () -> Unit,
    onRestore: () -> Unit,
    onDelete: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    val index = visibleInColumn.indexOfFirst { it.id == card.id }
    val canEarlier = !newestFirst && !working && canEdit && index > 0
    val canLater = !newestFirst && !working && canEdit && index >= 0 && index < visibleInColumn.size - 1
    TsCard {
        // `TsCard` already pads by `cardPaddingDp`; padding again inside it
        // was a second margin on all four sides, which is most of why these
        // cards stood so tall with so little in them.
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(Space.xs)) {
            // A clickable column, not a `TextButton`: the button imposes
            // Material's 48dp minimum height and centres what is inside it,
            // which left every card tall with its title floating in the
            // middle and a band of empty space above and below.
            Column(
                Modifier.fillMaxWidth().clickable(onClick = onEdit),
                verticalArrangement = Arrangement.spacedBy(Space.xs),
            ) {
                Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                    Text(
                        card.title,
                        style = TsType.body.copy(fontWeight = FontWeight.SemiBold),
                        color = LocalTsColors.current.textPrimary,
                        maxLines = 3,
                    )
                    if (card.notes.isNotEmpty()) {
                        Text(card.notes, style = TsType.caption, color = LocalTsColors.current.textSecondary, maxLines = 3)
                    }
                    if (showFolder) {
                        Text(folderName, style = TsType.caption, color = LocalTsColors.current.textSecondary)
                    }
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                val delegate = card.delegate
                if (delegate != null) {
                    Text(
                        delegate.label,
                        style = TsType.caption,
                        color = if (delegate.status == "error") LocalTsColors.current.danger else LocalTsColors.current.textSecondary,
                    )
                } else if (backendLabel.isNotEmpty()) {
                    Text(backendLabel, style = TsType.caption, color = LocalTsColors.current.textSecondary)
                }
                if (card.priority == "high") {
                    Text("High priority", style = TsType.caption, color = LocalTsColors.current.accent)
                }
                Spacer(Modifier.weight(1f))
                TextButton(onClick = { menu = true }, enabled = !working && canEdit) {
                    Text("Move")
                }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    BOARD_COLUMNS.forEach { (id, title, _) ->
                        if (card.column != id) {
                            DropdownMenuItem(
                                text = { Text("Move to $title") },
                                onClick = { menu = false; onMove(id, null, false) },
                            )
                        }
                    }
                    if (card.column != "archive") {
                        DropdownMenuItem(text = { Text("Archive") }, onClick = { menu = false; onArchive() })
                    } else {
                        DropdownMenuItem(text = { Text("Restore") }, onClick = { menu = false; onRestore() })
                    }
                    DropdownMenuItem(
                        text = { Text("Move earlier") },
                        enabled = canEarlier,
                        onClick = {
                            menu = false
                            if (index > 0) onMove(card.column, visibleInColumn[index - 1].id, false)
                        },
                    )
                    DropdownMenuItem(
                        text = { Text("Move later") },
                        enabled = canLater,
                        onClick = {
                            menu = false
                            if (index >= 0 && index + 2 < visibleInColumn.size) {
                                onMove(card.column, visibleInColumn[index + 2].id, false)
                            } else if (index >= 0) {
                                onMove(card.column, null, true)
                            }
                        },
                    )
                    DropdownMenuItem(
                        text = { Text("Delete") },
                        enabled = card.delegate?.isRunning != true && canDelete,
                        onClick = { menu = false; onDelete() },
                    )
                }
            }
        }
    }
}
