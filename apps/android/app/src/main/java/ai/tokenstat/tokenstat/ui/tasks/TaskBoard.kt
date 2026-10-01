// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.tasks

import ai.tokenstat.tokenstat.ui.localization.L10n

import ai.tokenstat.tokenstat.ui.components.ForegroundEffect
import ai.tokenstat.tokenstat.ui.chrome.OwnSectionHeader
import ai.tokenstat.tokenstat.ui.chrome.TabBarChrome

import androidx.compose.foundation.clickable

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.PaddingValues
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
    Triple("backlog", L10n.text("android.taskboard.to_do.150d92c4"), "backlog"),
    Triple("doing", L10n.text("android.taskboard.in_progress.c1f88e9d"), "doing"),
    Triple("done", L10n.text("common.done"), "done"),
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
    var selectedStage by remember(peer, fixedFolder) { mutableStateOf("backlog") }
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
            error = TunnelCopy.display(it.message ?: L10n.text("android.taskboard.the_request_failed.db4fb447"), hostLabel)
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
            error = L10n.text("android.taskboard.reload_the_board_before_moving_this_task.a24349b8")
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
            showNotice(if (column == "archive") L10n.text("android.taskboard.task_archived.0e7819fb") else L10n.text("android.taskboard.task_moved.c7ea8625"))
            error = null
            load(includeOptions = false)
        } catch (e: Exception) {
            error = L10n.text("android.taskboard.the_move_was_not_confirmed_reload_the_boar.ca497030", "${TunnelCopy.display(e.message ?: "", hostLabel)}")
        } finally {
            working = false
        }
    }

    suspend fun delete(card: TaskCard) {
        if (working || !canDelete) return
        val revision = card.revision
        if (revision == null) {
            error = L10n.text("android.taskboard.reload_the_board_before_deleting_this_task.7c0b8c41")
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
            showNotice(L10n.text("android.taskboard.task_deleted.d986a85e"))
            error = null
        } catch (e: Exception) {
            error = L10n.text("android.taskboard.the_deletion_was_not_confirmed_reload_the.bef65da3", "${TunnelCopy.display(e.message ?: "", hostLabel)}")
        } finally {
            working = false
        }
    }

    LaunchedEffect(peer) { load() }
    val anyRunning = cards.any { it.delegate?.isRunning == true }
    ForegroundEffect(anyRunning, peer) {
        if (!anyRunning) return@ForegroundEffect
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
                    Icon(ActionIcon.Back.vector, L10n.text("common.back"), tint = LocalTsColors.current.controlGlyph)
                }
                Column(Modifier.weight(1f)) {
                    Text(
                        if (fixedFolder == null) L10n.text("android.taskboard.all_tasks.cb664823") else L10n.text("common.tasks"),
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
                    Icon(ActionIcon.Create.vector, L10n.text("android.taskboard.new_task.3e992276"), tint = LocalTsColors.current.accent)
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                TsSecondaryButton(
                    label = L10n.text("android.taskboard.filters.546ebb8e"),
                    icon = ActionIcon.Filter.vector,
                    small = true,
                    onClick = { showFilters = !showFilters },
                )
                TsSecondaryButton(
                    label = if (filter.archived) L10n.text("android.taskboard.open_tasks.87cfa1a5") else L10n.text("common.archive"),
                    icon = if (filter.archived) ActionIcon.Restore.vector else ActionIcon.Archive.vector,
                    small = true,
                    onClick = { filter = filter.copy(archived = !filter.archived) },
                )
            }
            Spacer(Modifier.padding(top = Space.s))
            TsSearchField(
                prompt = L10n.text("android.taskboard.search_tasks.46c6f1de"),
                query = filter.query,
                onQueryChange = { filter = filter.copy(query = it) },
            )
            if (showFilters) {
                Spacer(Modifier.padding(top = Space.s))
                if (fixedFolder == null) {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                        ChoiceChip(L10n.text("android.taskboard.all_projects.4b87271b"), filter.folder is TaskBoardFolder.All, { filter = filter.copy(folder = TaskBoardFolder.All) })
                        ChoiceChip(L10n.text("android.taskboard.uncategorized.8d40d123"), filter.folder is TaskBoardFolder.Uncategorized, { filter = filter.copy(folder = TaskBoardFolder.Uncategorized) })
                        folders.forEach { folder ->
                            ChoiceChip(folder.name.ifBlank { folder.id }, filter.folder == TaskBoardFolder.Folder(folder.id), { filter = filter.copy(folder = TaskBoardFolder.Folder(folder.id)) })
                        }
                    }
                }
                FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                    ChoiceChip(L10n.text("android.taskboard.all_agents.54c32d3e"), filter.backend.isEmpty(), { filter = filter.copy(backend = "") })
                    agentIds.forEach { id ->
                        ChoiceChip(backends.firstOrNull { it.id == id }?.label ?: id, filter.backend == id, { filter = filter.copy(backend = id) })
                    }
                }
                FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                    TaskBoardAttention.entries.forEach { attention ->
                        ChoiceChip(attention.label, filter.attention == attention, { filter = filter.copy(attention = attention) })
                    }
                    ChoiceChip(L10n.text("android.taskboard.board_order.a919c850"), !filter.newestFirst, { filter = filter.copy(newestFirst = false) })
                    ChoiceChip(L10n.text("android.taskboard.newest_first.ffb6f576"), filter.newestFirst, { filter = filter.copy(newestFirst = true) })
                }
            }
            val summary = remember(filter, folders, backends, fixedFolder) {
                buildList {
                    if (fixedFolder == null) {
                        when (val folder = filter.folder) {
                            is TaskBoardFolder.Folder -> add(folders.firstOrNull { it.id == folder.id }?.name ?: L10n.text("android.taskboard.unavailable_folder.6454a349"))
                            is TaskBoardFolder.Uncategorized -> add(L10n.text("android.taskboard.uncategorized.8d40d123"))
                            is TaskBoardFolder.All -> Unit
                        }
                    }
                    if (filter.backend.isNotEmpty()) add(backends.firstOrNull { it.id == filter.backend }?.label ?: filter.backend)
                    if (filter.attention != TaskBoardAttention.ALL) add(filter.attention.label)
                    if (filter.newestFirst) add(L10n.text("android.taskboard.newest_first.ffb6f576"))
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
                    }) { Text(L10n.text("android.taskboard.clear_filters.7179ea00")) }
                }
            }
            if (error != null) {
                Banner(error!!, BannerSeverity.DANGER)
                TsSecondaryButton(label = L10n.text("android.taskboard.reload.bdc090ec"), small = true, onClick = { scope.launch { load() } })
            }
            if (!canEdit) {
                Text(
                    L10n.text("android.taskboard.update_0_s_tokenstat_to_use_all_task_editi.824b204a", "${hostLabel}"),
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
                    Text(L10n.text("android.taskboard.loading_tasks.cad82c71"), color = LocalTsColors.current.textSecondary)
                }
            }
            if (loaded && visible.isEmpty()) {
                EmptyState(
                    ActionIcon.Create.vector,
                    if (filter.archived) L10n.text("android.taskboard.no_archived_tasks.5cad3e05") else L10n.text("android.taskboard.no_tasks_here.befb28ae"),
                    L10n.text("android.taskboard.create_a_task_or_adjust_the_filters_to_see.50174b52"),
                    art = { EmptyArt(EmptyArtKind.Tasks) },
                )
            }
            if (!filter.archived) {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                    BOARD_COLUMNS.forEach { (id, title, _) ->
                        ChoiceChip("$title (${visible.count { it.column == id }})", selectedStage == id, { selectedStage = id })
                    }
                }
            }
            PullToRefreshBox(isRefreshing = loading && loaded, onRefresh = { scope.launch { load() } }, modifier = Modifier.weight(1f)) {
                LazyColumn(
                    Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(bottom = TabBarChrome.contentBottomInset),
                    verticalArrangement = Arrangement.spacedBy(Space.s),
                ) {
                    val columns = if (filter.archived) listOf(Triple("archive", L10n.text("common.archive"), "archive")) else BOARD_COLUMNS.filter { it.first == selectedStage }
                    columns.forEach { (id, title, _) ->
                        item(key = "header-$id") {
                            val count = visible.count { it.column == id }
                            SectionLabel(title, count)
                        }
                        val columnCards = visible.filter { it.column == id }
                        if (columnCards.isEmpty()) {
                            item(key = "empty-$id") {
                                Text(when (id) {
                                    "backlog" -> L10n.text("android.taskboard.ready_for_your_next_task.838d6e4b")
                                    "doing" -> L10n.text("android.taskboard.nothing_in_progress.44a3cc77")
                                    "done" -> L10n.text("android.taskboard.completed_tasks_appear_here.6d7064fc")
                                    else -> L10n.text("android.taskboard.no_archived_tasks.5cad3e05")
                                }, style = TsType.caption, color = LocalTsColors.current.textSecondary)
                            }
                        }
                        items(columnCards, key = { "task-${it.id}" }) { card ->
                            TaskRow(
                                card = card,
                                showFolder = fixedFolder == null,
                                folderName = folders.firstOrNull { it.id == card.workspaceID }?.name
                                    ?: if (card.workspaceID.isEmpty()) L10n.text("android.taskboard.uncategorized.8d40d123") else L10n.text("android.taskboard.unavailable_folder.6454a349"),
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
            title = { Text(L10n.text("android.taskboard.delete_task.6f2142f0")) },
            text = { Text(L10n.text("android.taskboard.delete_0_this_removes_the_task_from_this_c.615625b6", "${deletingCard.title}")) },
            confirmButton = {
                Button(onClick = { scope.launch { delete(deletingCard) } }) { Text(L10n.text("android.taskboard.delete_task.3baf5547")) }
            },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text(L10n.text("common.cancel")) } },
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
                    Text(L10n.text("android.taskboard.high_priority.b699a8c8"), style = TsType.caption, color = LocalTsColors.current.accent)
                }
                Spacer(Modifier.weight(1f))
                TextButton(onClick = { menu = true }, enabled = !working && canEdit) {
                    Text(L10n.text("android.taskboard.move.6ecc3df6"))
                }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    BOARD_COLUMNS.forEach { (id, title, _) ->
                        if (card.column != id) {
                            DropdownMenuItem(
                                text = { Text(L10n.text("android.taskboard.move_to_0.699bb2f5", "${title}")) },
                                onClick = { menu = false; onMove(id, null, false) },
                            )
                        }
                    }
                    if (card.column != "archive") {
                        DropdownMenuItem(text = { Text(L10n.text("common.archive")) }, onClick = { menu = false; onArchive() })
                    } else {
                        DropdownMenuItem(text = { Text(L10n.text("common.restore")) }, onClick = { menu = false; onRestore() })
                    }
                    DropdownMenuItem(
                        text = { Text(L10n.text("android.taskboard.move_earlier.736612d4")) },
                        enabled = canEarlier,
                        onClick = {
                            menu = false
                            if (index > 0) onMove(card.column, visibleInColumn[index - 1].id, false)
                        },
                    )
                    DropdownMenuItem(
                        text = { Text(L10n.text("android.taskboard.move_later.d6e85608")) },
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
                        text = { Text(L10n.text("common.delete")) },
                        enabled = card.delegate?.isRunning != true && canDelete,
                        onClick = { menu = false; onDelete() },
                    )
                }
            }
        }
    }
}
