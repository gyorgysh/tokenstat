// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workflows

import ai.tokenstat.tokenstat.ui.components.ForegroundEffect
import ai.tokenstat.tokenstat.ui.chrome.OwnSectionHeader

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.automations.AllRunsRow
import ai.tokenstat.tokenstat.ui.automations.AutomationJob
import ai.tokenstat.tokenstat.ui.automations.AutomationQueue
import ai.tokenstat.tokenstat.ui.automations.HostScheduleClock
import ai.tokenstat.tokenstat.ui.automations.JobConfirmDialog
import ai.tokenstat.tokenstat.ui.automations.JobCopy
import ai.tokenstat.tokenstat.ui.automations.JobFactRow
import ai.tokenstat.tokenstat.ui.automations.JobGoneCard
import ai.tokenstat.tokenstat.ui.automations.JobScreenHeader
import ai.tokenstat.tokenstat.ui.automations.JobStatusPill
import ai.tokenstat.tokenstat.ui.automations.PastRunRow
import ai.tokenstat.tokenstat.ui.automations.deviceDateTime
import ai.tokenstat.tokenstat.ui.automations.pastRunWhen
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.BrandToggleChip
import ai.tokenstat.tokenstat.ui.components.EmptyState
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsSearchField
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.logic.HostContracts
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import ai.tokenstat.tokenstat.ui.marks.EmptyArt
import ai.tokenstat.tokenstat.ui.marks.EmptyArtKind
import ai.tokenstat.tokenstat.ui.tasks.BackendRef
import ai.tokenstat.tokenstat.ui.tasks.FolderRef
import ai.tokenstat.tokenstat.ui.tasks.RunHistory
import ai.tokenstat.tokenstat.ui.tasks.RunRef
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import java.util.UUID
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

private sealed interface WorkflowRoute {
    data object List : WorkflowRoute
    data class Detail(val graphID: String) : WorkflowRoute
    data class History(val graphID: String) : WorkflowRoute
    data class Run(val graphID: String, val runID: String) : WorkflowRoute
    data object Create : WorkflowRoute
    data class Edit(val graphID: String) : WorkflowRoute
}

private sealed interface WorkflowConfirm {
    data class Run(val graphID: String, val input: String) : WorkflowConfirm
    data class Stop(val runID: String) : WorkflowConfirm
    data class Continue(val runID: String) : WorkflowConfirm
    data class Delete(val graphID: String) : WorkflowConfirm
}

@Composable
fun WorkflowsDialog(
    model: AppViewModel,
    peer: String,
    hostLabel: String,
    protocol: Long?,
    workspaceID: String,
    folderName: String,
    onDismiss: () -> Unit,
) {
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        WorkflowsScreen(
            model = model,
            peer = peer,
            hostLabel = hostLabel,
            protocol = protocol,
            workspaceID = workspaceID,
            folderName = folderName,
            onBack = onDismiss,
        )
    }
}

/// The workflows workbench as full pages: list, detail, history, run, and
/// the editor. Ports `ClientWorkflowWorkspace` (phone list), the detail,
/// history and run views, and the `ClientWorkflowSession` operation rules.
///
/// Saves are `workflow.edit` with the baseline revision on protocol 22+
/// hosts, `workflow.update` below that, with the re-read-and-compare
/// recovery instead of a blind retry.
@Composable
fun WorkflowsScreen(
    model: AppViewModel,
    peer: String,
    hostLabel: String,
    protocol: Long?,
    workspaceID: String,
    folderName: String,
    onBack: () -> Unit,
) {
    // This screen brings its own header, its own back and its own add,
    // so the section header above it steps aside rather than stacking a
    // second copy of the same title and arrow.
    OwnSectionHeader()
    val scope = rememberCoroutineScope()
    val supportsEdits = HostContracts.supportsWorkflowEditing(protocol)
    var graphs by remember { mutableStateOf<List<WorkflowGraph>>(emptyList()) }
    var runs by remember { mutableStateOf<List<WorkflowRunRecord>>(emptyList()) }
    var backends by remember { mutableStateOf<List<AgentBackend>>(emptyList()) }
    var automations by remember { mutableStateOf<List<AutomationJob>>(emptyList()) }
    var folders by remember { mutableStateOf<List<FolderRef>>(emptyList()) }
    var queue by remember { mutableStateOf(AutomationQueue()) }
    var loaded by remember { mutableStateOf(false) }
    var loading by remember { mutableStateOf(true) }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var notice by remember { mutableStateOf<String?>(null) }
    var stack by remember { mutableStateOf(listOf<WorkflowRoute>(WorkflowRoute.List)) }
    var search by remember { mutableStateOf("") }
    var inputs by remember { mutableStateOf(mapOf<String, String>()) }
    var shownRuns by remember { mutableStateOf(mapOf<String, Int>()) }
    var selectedSteps by remember { mutableStateOf(mapOf<String, String>()) }
    var confirm by remember { mutableStateOf<WorkflowConfirm?>(null) }

    val route = stack.last()
    fun push(next: WorkflowRoute) {
        stack = (stack + next).takeLast(8)
    }
    fun pop() {
        stack = if (stack.size > 1) stack.dropLast(1) else stack
    }
    fun dropGraph(graphID: String) {
        stack = (listOf(WorkflowRoute.List) + stack.filter {
            when (it) {
                is WorkflowRoute.List -> false
                is WorkflowRoute.Detail -> it.graphID != graphID
                is WorkflowRoute.History -> it.graphID != graphID
                is WorkflowRoute.Run -> it.graphID != graphID
                is WorkflowRoute.Create -> true
                is WorkflowRoute.Edit -> it.graphID != graphID
            }
        }).distinct()
    }

    suspend fun load() {
        loading = true
        runCatching { model.workspaceSection(peer, "workflow.list", buildJsonObject {}) }
            .onSuccess { element ->
                graphs = ((element as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()).map(WorkflowGraph::parse)
                loaded = true
                error = null
            }
            .onFailure { error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
        runCatching { model.workspaceSection(peer, "workflow.runs", buildJsonObject {}) }
            .onSuccess { element ->
                runs = ((element as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()).map(WorkflowRunRecord::parse)
            }
        runCatching { model.workspaceSection(peer, "automation.backends", buildJsonObject {}) }
            .onSuccess { element ->
                backends = ((element as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()).map(AgentBackend::parse)
            }
        runCatching { model.workspaceSection(peer, "automation.list", buildJsonObject {}) }
            .onSuccess { element ->
                automations = ((element as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()).map(AutomationJob::parse)
            }
        runCatching { model.workspaceSection(peer, "workspace.list", buildJsonObject {}) }
            .onSuccess { element ->
                folders = ((element as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()).map(FolderRef::parse)
            }
        runCatching { model.workspaceSection(peer, "automation.queue", buildJsonObject {}) }
            .onSuccess { element -> queue = AutomationQueue.parse(element as? JsonObject) }
        loading = false
    }

    suspend fun run(graph: WorkflowGraph, input: String) {
        val issue = WorkflowGraphRules.stepsIssue(graph.nodes, graph.edges)
        if (issue != null) {
            error = "$issue Fix it in the editor before running."
            return
        }
        working = true
        runCatching {
            model.workspaceSection(peer, "workflow.run", buildJsonObject {
                put("id", graph.id)
                put("input", input)
                if (graph.workspaceID?.isNotEmpty() == true) put("workspaceId", graph.workspaceID!!)
            })
        }.onSuccess {
            notice = "Started ${graph.name}."
            error = null
            load()
        }.onFailure {
            error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel)
        }
        working = false
    }

    suspend fun stop(run: WorkflowRunRecord) {
        working = true
        runCatching {
            model.workspaceSection(peer, "workflow.kill", buildJsonObject { put("id", run.id) })
        }.onSuccess {
            notice = "Stopped ${run.name}."
            error = null
            load()
        }.onFailure {
            error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel)
        }
        working = false
    }

    suspend fun continueRun(run: WorkflowRunRecord) {
        working = true
        runCatching {
            model.workspaceSection(peer, "workflow.continue", buildJsonObject { put("id", run.id) })
        }.onSuccess {
            notice = "Continued ${run.name}."
            error = null
            load()
        }.onFailure {
            error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel)
        }
        working = false
    }

    suspend fun toggleSchedule(graph: WorkflowGraph) {
        if (working || !graph.schedule.repeats) return
        working = true
        // The host replaces the whole graph. Re-read first so a stale
        // phone copy cannot wipe a newer edit.
        val fresh = runCatching {
            model.workspaceSection(peer, "workflow.list", buildJsonObject {})
        }.getOrNull()?.let { element ->
            ((element as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList())
                .map(WorkflowGraph::parse).firstOrNull { it.id == graph.id }
        }
        if (fresh == null) {
            error = "This workflow is gone. Reload the list before changing it."
            working = false
            return
        }
        val toggled = fresh.copy(enabled = !fresh.enabled)
        runCatching {
            if (supportsEdits) {
                model.workspaceSection(peer, "workflow.edit", buildJsonObject {
                    put("workflow", toggled.toJson())
                    put("expectedRevision", fresh.revision)
                })
            } else {
                model.workspaceSection(peer, "workflow.update", buildJsonObject {
                    put("workflow", toggled.toJson())
                })
            }
        }.onSuccess {
            error = null
            load()
        }.onFailure {
            error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel)
        }
        working = false
    }

    suspend fun remove(graph: WorkflowGraph) {
        working = true
        runCatching {
            model.workspaceSection(peer, "workflow.remove", buildJsonObject { put("id", graph.id) })
        }.onSuccess {
            dropGraph(graph.id)
            notice = "Deleted ${graph.name}."
            error = null
            load()
        }.onFailure {
            error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel)
        }
        working = false
    }

    LaunchedEffect(peer) { load() }
    val anyLive = runs.any { it.isLive }
    ForegroundEffect(anyLive, peer) {
        if (!anyLive) return@ForegroundEffect
        while (true) {
            delay(3_000)
            if (!working && !loading) load()
        }
    }
    BackHandler {
        if (confirm != null) confirm = null
        else if (stack.size > 1) pop()
        else onBack()
    }

    val scoped = remember(graphs, workspaceID) {
        graphs.filter { it.workspaceID == workspaceID || (it.scope == WorkflowScope.GLOBAL && workspaceID.isEmpty()) }
    }
    val timezone = HostScheduleClock.resolved(queue.timezone)
    val folderCaption = folderName.ifBlank { hostLabel }

    Column(
        Modifier
            .fillMaxSize()
            .background(LocalTsColors.current.background)
            .padding(Space.m),
    ) {
        when (route) {
            is WorkflowRoute.List -> WorkflowListPage(
                scoped = scoped,
                runs = runs,
                loaded = loaded,
                loading = loading,
                working = working,
                error = error,
                notice = notice,
                search = search,
                supportsEdits = supportsEdits,
                hostLabel = hostLabel,
                folderCaption = folderCaption,
                queueTimezone = queue.timezone,
                onSearch = { search = it },
                onReload = { scope.launch { load() } },
                onBack = onBack,
                onOpen = { push(WorkflowRoute.Detail(it)) },
                onCreate = { push(WorkflowRoute.Create) },
                onEdit = { push(WorkflowRoute.Edit(it)) },
                onDelete = { confirm = WorkflowConfirm.Delete(it) },
            )
            is WorkflowRoute.Detail -> {
                val graph = scoped.firstOrNull { it.id == route.graphID }
                WorkflowDetailPage(
                    graph = graph,
                    loaded = loaded,
                    loading = loading,
                    working = working,
                    error = error,
                    notice = notice,
                    runs = runs.filter { it.workflowID == route.graphID },
                    hostLabel = hostLabel,
                    folderName = folderName,
                    queueTimezone = queue.timezone,
                    input = inputs[route.graphID].orEmpty(),
                    onInput = { inputs = inputs + (route.graphID to it) },
                    onReload = { scope.launch { load() } },
                    onBack = ::pop,
                    onEdit = { push(WorkflowRoute.Edit(route.graphID)) },
                    onDelete = { confirm = WorkflowConfirm.Delete(route.graphID) },
                    onRun = { confirm = WorkflowConfirm.Run(route.graphID, inputs[route.graphID].orEmpty()) },
                    onStop = { confirm = WorkflowConfirm.Stop(it) },
                    onContinue = { confirm = WorkflowConfirm.Continue(it) },
                    onToggle = { g -> scope.launch { toggleSchedule(g) } },
                    onHistory = { push(WorkflowRoute.History(route.graphID)) },
                    onRunOpen = { push(WorkflowRoute.Run(route.graphID, it)) },
                )
            }
            is WorkflowRoute.History -> WorkflowHistoryPage(
                graph = scoped.firstOrNull { it.id == route.graphID },
                runs = runs.filter { it.workflowID == route.graphID },
                loaded = loaded,
                loading = loading,
                hostLabel = hostLabel,
                queueTimezone = queue.timezone,
                shown = shownRuns[route.graphID] ?: RunHistory.PAGE_SIZE,
                onMore = { shownRuns = shownRuns + (route.graphID to ((shownRuns[route.graphID] ?: RunHistory.PAGE_SIZE) + RunHistory.PAGE_SIZE)) },
                onReload = { scope.launch { load() } },
                onBack = ::pop,
                onRunOpen = { push(WorkflowRoute.Run(route.graphID, it)) },
            )
            is WorkflowRoute.Run -> {
                val run = runs.firstOrNull { it.id == route.runID }
                WorkflowRunPage(
                    model = model,
                    peer = peer,
                    run = run,
                    loaded = loaded,
                    loading = loading,
                    working = working,
                    error = error,
                    hostLabel = hostLabel,
                    selectedNodeID = selectedSteps[route.runID],
                    onSelectNode = { selectedSteps = selectedSteps + (route.runID to it) },
                    onReload = { scope.launch { load() } },
                    onBack = ::pop,
                    onStop = { confirm = WorkflowConfirm.Stop(route.runID) },
                    onContinue = { confirm = WorkflowConfirm.Continue(route.runID) },
                )
            }
            is WorkflowRoute.Create -> WorkflowEditorScreen(
                model = model,
                peer = peer,
                hostLabel = hostLabel,
                protocol = protocol,
                workspaceID = workspaceID,
                folderName = folderName,
                existing = null,
                backends = backends,
                backendRefs = backends.map { BackendRef(it.id, it.label, it.models, it.efforts) },
                automations = automations,
                folders = folders,
                defaultBudget = queue.defaultBudgetSeconds,
                timezone = timezone.orEmpty(),
                onSaved = { scope.launch { load() } },
                onBack = ::pop,
            )
            is WorkflowRoute.Edit -> WorkflowEditorScreen(
                model = model,
                peer = peer,
                hostLabel = hostLabel,
                protocol = protocol,
                workspaceID = workspaceID,
                folderName = folderName,
                existing = scoped.firstOrNull { it.id == route.graphID },
                backends = backends,
                backendRefs = backends.map { BackendRef(it.id, it.label, it.models, it.efforts) },
                automations = automations,
                folders = folders,
                defaultBudget = queue.defaultBudgetSeconds,
                timezone = timezone.orEmpty(),
                onSaved = { scope.launch { load() } },
                onBack = ::pop,
            )
        }
    }
    val pending = confirm
    if (pending != null) {
        val graph = graphs.firstOrNull {
            it.id == when (pending) {
                is WorkflowConfirm.Run -> pending.graphID
                is WorkflowConfirm.Delete -> pending.graphID
                is WorkflowConfirm.Stop -> runs.firstOrNull { item -> item.id == pending.runID }?.workflowID
                is WorkflowConfirm.Continue -> runs.firstOrNull { item -> item.id == pending.runID }?.workflowID
            }
        }
        val targetRun = when (pending) {
            is WorkflowConfirm.Stop -> runs.firstOrNull { it.id == pending.runID }
            is WorkflowConfirm.Continue -> runs.firstOrNull { it.id == pending.runID }
            else -> null
        }
        val name = graph?.name?.ifBlank { "this workflow" } ?: "this workflow"
        val place = folderName.ifBlank { "this folder" }
        when (pending) {
            is WorkflowConfirm.Run -> JobConfirmDialog(
                title = "Run $name?",
                message = JobCopy.run(name, place, hostLabel),
                confirmLabel = "Run",
                onConfirm = {
                    val target = graphs.firstOrNull { it.id == pending.graphID }
                    if (target != null) scope.launch { run(target, pending.input) }
                },
                onDismiss = { confirm = null },
            )
            is WorkflowConfirm.Stop -> if (targetRun != null) JobConfirmDialog(
                title = "Stop $name?",
                message = JobCopy.stop(name, place, hostLabel),
                confirmLabel = "Stop",
                destructive = true,
                onConfirm = { scope.launch { stop(targetRun) } },
                onDismiss = { confirm = null },
            )
            is WorkflowConfirm.Continue -> if (targetRun != null) JobConfirmDialog(
                title = "Continue $name?",
                message = JobCopy.continueGate(name, place, hostLabel),
                confirmLabel = "Continue",
                onConfirm = { scope.launch { continueRun(targetRun) } },
                onDismiss = { confirm = null },
            )
            is WorkflowConfirm.Delete -> if (graph != null) JobConfirmDialog(
                title = "Delete $name?",
                message = "The graph is removed. Past runs stay on this computer.",
                confirmLabel = "Delete",
                destructive = true,
                onConfirm = { scope.launch { remove(graph) } },
                onDismiss = { confirm = null },
            )
        }
    }
}

private fun orderedWorkflowRuns(runs: List<WorkflowRunRecord>): List<WorkflowRunRecord> {
    val ordered = RunHistory.ordered(runs.map { RunRef(it.id, it.startedAtMs, it.isLive) })
    val byID = runs.associateBy { it.id }
    return ordered.mapNotNull { byID[it.id] }
}

/// The library: search, summary, and one row per graph. Port of the
/// `ClientWorkflowWorkspace` phone list.
@Composable
private fun WorkflowListPage(
    scoped: List<WorkflowGraph>,
    runs: List<WorkflowRunRecord>,
    loaded: Boolean,
    loading: Boolean,
    working: Boolean,
    error: String?,
    notice: String?,
    search: String,
    supportsEdits: Boolean,
    hostLabel: String,
    folderCaption: String,
    queueTimezone: String?,
    onSearch: (String) -> Unit,
    onReload: () -> Unit,
    onBack: () -> Unit,
    onOpen: (String) -> Unit,
    onCreate: () -> Unit,
    onEdit: (String) -> Unit,
    onDelete: (String) -> Unit,
) {
    val filtered = remember(scoped, search) { scoped.filter { graphMatchesQuery(it, search) } }
    val liveCount = remember(runs, scoped) {
        val ids = scoped.map { it.id }.toSet()
        runs.count { it.isLive && it.workflowID in ids }
    }
    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(Space.s)) {
        JobScreenHeader(
            title = "Workflows",
            subtitle = folderCaption,
            onBack = onBack,
            actions = {
                IconButton(onClick = onCreate) {
                    Icon(ActionIcon.Create.vector, "New workflow", tint = LocalTsColors.current.accent)
                }
            },
        )
        if (!supportsEdits) {
            Text(
                "Update $hostLabel's tokenstat to save workflows from here. Below protocol 22 every save is last-write-wins.",
                style = TsType.caption,
                color = LocalTsColors.current.textSecondary,
            )
        }
        if (error != null) {
            Banner(error, BannerSeverity.DANGER)
            TsSecondaryButton(label = "Reload", small = true, onClick = onReload)
        }
        if (notice != null) {
            Text(notice, style = TsType.caption, color = LocalTsColors.current.textSecondary)
        }
        TsSearchField(prompt = "Search workflows", query = search, onQueryChange = onSearch)
        if (loaded && scoped.isNotEmpty()) {
            Text(
                workflowListSummary(scoped.size, liveCount),
                style = TsType.caption,
                color = LocalTsColors.current.textSecondary,
            )
        }
        if (loading && !loaded) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                CircularProgressIndicator()
                Text("Loading workflows", color = LocalTsColors.current.textSecondary)
            }
        }
        PullToRefreshBox(isRefreshing = loading && loaded, onRefresh = onReload, modifier = Modifier.weight(1f)) {
            LazyColumn(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(Space.s)) {
                if (loaded && scoped.isEmpty()) {
                    item {
                        EmptyState(
                            ActionIcon.Plan.vector,
                            "No workflows here",
                            "Create a workflow for this folder. It runs on the connected computer.",
                            art = { EmptyArt(EmptyArtKind.Workflows) },
                            action = {
                                TsAccentButton(label = "New workflow", icon = ActionIcon.Create.vector, small = true, onClick = onCreate)
                            },
                        )
                    }
                } else if (loaded && filtered.isEmpty()) {
                    item {
                        Text(
                            "No matching workflows",
                            style = TsType.body,
                            color = LocalTsColors.current.textSecondary,
                        )
                    }
                }
                items(filtered, key = { it.id }) { graph ->
                    WorkflowJobRow(
                        graph = graph,
                        subtitle = HostScheduleClock.listSubtitle(
                            graph.schedule.summary,
                            graph.nextRunAtMs,
                            graph.enabled,
                            graph.schedule.repeats,
                            queueTimezone,
                        ),
                        isLive = runs.any { it.workflowID == graph.id && it.isLive },
                        working = working,
                        onOpen = { onOpen(graph.id) },
                        onEdit = { onEdit(graph.id) },
                        onDelete = { onDelete(graph.id) },
                    )
                }
            }
        }
    }
}

/// A graph as a name, one quiet line, and whether it is going.
/// Port of `ClientJobRow`.
@Composable
private fun WorkflowJobRow(
    graph: WorkflowGraph,
    subtitle: String,
    isLive: Boolean,
    working: Boolean,
    onOpen: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    val colors = LocalTsColors.current
    var menu by remember { mutableStateOf(false) }
    val isPaused = !graph.enabled && graph.schedule.repeats
    TsCard {
        Row(
            Modifier
                .fillMaxWidth()
                .clickable(onClick = onOpen)
                .padding(Space.m),
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(Space.s),
        ) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    graph.name.ifBlank { "Untitled" },
                    style = TsType.subheadline.copy(fontWeight = FontWeight.Medium),
                    color = colors.textPrimary,
                    maxLines = 2,
                )
                Text(subtitle, style = TsType.caption, color = colors.textSecondary, maxLines = 1)
            }
            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                if (isLive) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                        Canvas(Modifier.size(7.dp)) { drawCircle(colors.stateWorking) }
                        Text("Running", style = TsType.caption, color = colors.stateWorking)
                    }
                } else if (isPaused) {
                    Text("Paused", style = TsType.caption, color = colors.textTertiary)
                }
                Box {
                    IconButton(onClick = { menu = true }, enabled = !working) {
                        Icon(ActionIcon.More.vector, "Workflow actions", tint = colors.controlGlyph)
                    }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        DropdownMenuItem(text = { Text("Open") }, onClick = { menu = false; onOpen() })
                        DropdownMenuItem(text = { Text("Edit") }, onClick = { menu = false; onEdit() })
                        DropdownMenuItem(text = { Text("Delete") }, onClick = { menu = false; onDelete() })
                    }
                }
            }
        }
    }
}

/// One graph on a phone: the picture, a prompt, Run / Stop / Continue.
/// Port of `ClientWorkflowDetailView`.
@Composable
private fun WorkflowDetailPage(
    graph: WorkflowGraph?,
    loaded: Boolean,
    loading: Boolean,
    working: Boolean,
    error: String?,
    notice: String?,
    runs: List<WorkflowRunRecord>,
    hostLabel: String,
    folderName: String,
    queueTimezone: String?,
    input: String,
    onInput: (String) -> Unit,
    onReload: () -> Unit,
    onBack: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
    onRun: () -> Unit,
    onStop: (String) -> Unit,
    onContinue: (String) -> Unit,
    onToggle: (WorkflowGraph) -> Unit,
    onHistory: () -> Unit,
    onRunOpen: (String) -> Unit,
) {
    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(Space.s)) {
        JobScreenHeader(
            title = graph?.name?.ifBlank { "Workflow" } ?: "Workflow",
            subtitle = folderName.ifBlank { hostLabel },
            onBack = onBack,
            actions = {
                if (graph != null) {
                    IconButton(onClick = onEdit) {
                        Icon(ActionIcon.Edit.vector, "Edit", tint = LocalTsColors.current.controlGlyph)
                    }
                    IconButton(onClick = onDelete) {
                        Icon(ActionIcon.Delete.vector, "Delete", tint = LocalTsColors.current.danger)
                    }
                }
            },
        )
        PullToRefreshBox(isRefreshing = loading && loaded, onRefresh = onReload, modifier = Modifier.weight(1f)) {
            Column(
                Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(Space.s),
            ) {
                if (error != null) {
                    Banner(error, BannerSeverity.DANGER)
                    TsSecondaryButton(label = "Reload", small = true, onClick = onReload)
                }
                if (notice != null) {
                    Text(notice, style = TsType.caption, color = LocalTsColors.current.textSecondary)
                }
                if (graph == null) {
                    if (loaded) {
                        JobGoneCard("This workflow is gone", "It is not in the folder any more.")
                    } else {
                        CircularProgressIndicator()
                    }
                    return@Column
                }
                val live = runs.firstOrNull { it.isLive }
                TsCard {
                    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                        Text(hostLabel, style = TsType.caption, color = LocalTsColors.current.textSecondary)
                        Row(horizontalArrangement = Arrangement.spacedBy(Space.m)) {
                            JobFactRow("Schedule", graph.schedule.summary, Modifier.weight(1f))
                            JobFactRow("Budget", JobCopy.budget(graph.budgetSeconds), Modifier.weight(1f))
                        }
                        val place = HostScheduleClock.place(queueTimezone)
                        if (place != null || (graph.nextRunAtMs != null && graph.enabled)) {
                            Row(horizontalArrangement = Arrangement.spacedBy(Space.m)) {
                                if (place != null) {
                                    JobFactRow("Time zone", place, Modifier.weight(1f))
                                } else {
                                    Box(Modifier.weight(1f))
                                }
                                val next = graph.nextRunAtMs
                                if (next != null && graph.enabled) {
                                    JobFactRow("Next", HostScheduleClock.nextRun(next, queueTimezone), Modifier.weight(1f))
                                } else {
                                    Box(Modifier.weight(1f))
                                }
                            }
                        }
                        val lastStarted = lastWorkflowRun(runs, graph)?.startedAtMs?.takeIf { it > 0 }
                            ?: graph.lastRunAtMs?.takeIf { it > 0 }
                        JobFactRow("Last", JobCopy.lastRunWhen(lastStarted))
                    }
                }
                if (graph.nodes.isNotEmpty()) {
                    WorkflowPicture(graph = graph, currentNodeID = live?.currentNodeID)
                }
                TsCard {
                    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                        if (live != null) {
                            Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                                if (live.isWaiting) {
                                    TsAccentButton(
                                        label = if (working) "Working" else "Continue",
                                        enabled = !working,
                                        onClick = { onContinue(live.id) },
                                    )
                                }
                                TsSecondaryButton(
                                    label = "Stop",
                                    icon = ActionIcon.Stop.vector,
                                    enabled = !working,
                                    onClick = { onStop(live.id) },
                                )
                            }
                        } else {
                            OutlinedTextField(
                                input,
                                onInput,
                                modifier = Modifier.fillMaxWidth(),
                                label = { Text("Starting prompt") },
                                minLines = 3,
                            )
                            TsAccentButton(
                                label = if (working) "Starting" else "Run",
                                icon = ActionIcon.Run.vector,
                                enabled = !working,
                                onClick = onRun,
                            )
                        }
                        if (graph.schedule.repeats) {
                            BrandToggleChip(if (graph.enabled) "On" else "Off", graph.enabled, { onToggle(graph) })
                        }
                    }
                }
                val ordered = remember(runs) { orderedWorkflowRuns(runs) }
                val preview = remember(ordered) { ordered.take(RunHistory.PREVIEW_COUNT) }
                if (preview.isNotEmpty()) {
                    Text(
                        "Recent runs",
                        style = TsType.caption.copy(fontWeight = FontWeight.SemiBold),
                        color = LocalTsColors.current.textTertiary,
                    )
                    if (RunHistory.showsAllRuns(ordered.size)) {
                        AllRunsRow(count = ordered.size, onOpen = onHistory)
                    }
                    preview.forEach { run ->
                        PastRunRow(
                            title = run.name,
                            status = run.status,
                            label = run.endedLabel,
                            whenText = pastRunWhen(run.startedAtMs, queueTimezone),
                            onOpen = { onRunOpen(run.id) },
                        )
                    }
                }
            }
        }
    }
}

/// The graph as named step capsules, top to bottom. The canvas stays on
/// the Mac; this is the phone reading of the same order.
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun WorkflowPicture(graph: WorkflowGraph, currentNodeID: String?) {
    val colors = LocalTsColors.current
    TsCard {
        FlowRow(
            Modifier.padding(Space.m),
            horizontalArrangement = Arrangement.spacedBy(Space.xs),
            verticalArrangement = Arrangement.spacedBy(Space.xs),
        ) {
            graph.nodes.forEachIndexed { index, node ->
                val current = currentNodeID == node.id
                Box(
                    Modifier
                        .clip(RoundedCornerShape(8.dp))
                        .background(if (current) colors.accentSoft else colors.controlSeat)
                        .padding(horizontal = Space.s, vertical = Space.xs),
                ) {
                    Text(
                        "${index + 1}. ${node.title.ifBlank { node.kind.label }}",
                        style = TsType.caption.copy(fontWeight = FontWeight.Medium),
                        color = colors.textPrimary,
                    )
                }
            }
        }
    }
}

/// Every retained run for one workflow, live first, twenty at a time.
/// Port of `ClientWorkflowHistoryView`.
@Composable
private fun WorkflowHistoryPage(
    graph: WorkflowGraph?,
    runs: List<WorkflowRunRecord>,
    loaded: Boolean,
    loading: Boolean,
    hostLabel: String,
    queueTimezone: String?,
    shown: Int,
    onMore: () -> Unit,
    onReload: () -> Unit,
    onBack: () -> Unit,
    onRunOpen: (String) -> Unit,
) {
    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(Space.s)) {
        JobScreenHeader(
            title = "Runs",
            subtitle = graph?.name.orEmpty(),
            onBack = onBack,
        )
        PullToRefreshBox(isRefreshing = loading && loaded, onRefresh = onReload, modifier = Modifier.weight(1f)) {
            Column(
                Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(Space.s),
            ) {
                if (!loaded) {
                    CircularProgressIndicator()
                    return@Column
                }
                if (runs.isEmpty()) {
                    EmptyState(
                        ActionIcon.History.vector,
                        "Nothing has run yet",
                        "When this workflow runs, the output lands here.",
                    )
                    return@Column
                }
                val ordered = orderedWorkflowRuns(runs)
                val visible = ordered.take(maxOf(0, shown))
                val leftover = RunHistory.remaining(runs.size, shown)
                Text(
                    HostScheduleClock.timesCaption(hostLabel, queueTimezone),
                    style = TsType.caption,
                    color = LocalTsColors.current.textSecondary,
                )
                if (leftover > 0) {
                    Text(
                        "Showing the ${visible.size} newest of ${runs.size}.",
                        style = TsType.caption,
                        color = LocalTsColors.current.textSecondary,
                    )
                }
                visible.forEach { run ->
                    PastRunRow(
                        title = run.name,
                        status = run.status,
                        label = run.endedLabel,
                        whenText = pastRunWhen(run.startedAtMs, queueTimezone),
                        onOpen = { onRunOpen(run.id) },
                    )
                }
                if (leftover > 0) {
                    TsSecondaryButton(label = "Earlier runs", icon = ActionIcon.History.vector, small = true, onClick = onMore)
                }
            }
        }
    }
}

/// One workflow run: steps and the transcript of the selected step.
/// Port of `ClientWorkflowRunView`.
@Composable
private fun WorkflowRunPage(
    model: AppViewModel,
    peer: String,
    run: WorkflowRunRecord?,
    loaded: Boolean,
    loading: Boolean,
    working: Boolean,
    error: String?,
    hostLabel: String,
    selectedNodeID: String?,
    onSelectNode: (String) -> Unit,
    onReload: () -> Unit,
    onBack: () -> Unit,
    onStop: () -> Unit,
    onContinue: () -> Unit,
) {
    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(Space.s)) {
        JobScreenHeader(
            title = run?.name?.ifBlank { "Run" } ?: "Run",
            subtitle = hostLabel,
            onBack = onBack,
        )
        PullToRefreshBox(isRefreshing = loading && loaded, onRefresh = onReload, modifier = Modifier.weight(1f)) {
            Column(
                Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(Space.s),
            ) {
                if (error != null) {
                    Banner(error, BannerSeverity.DANGER)
                    TsSecondaryButton(label = "Reload", small = true, onClick = onReload)
                }
                if (run == null) {
                    if (loaded) {
                        JobGoneCard("This run is unavailable", "It is no longer in this folder's run history.")
                    } else {
                        CircularProgressIndicator()
                    }
                    return@Column
                }
                TsCard {
                    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            JobStatusPill(run.status, run.endedLabel, Modifier.weight(1f))
                            Text(
                                deviceDateTime(run.startedAtMs),
                                style = TsType.caption,
                                color = LocalTsColors.current.textSecondary,
                            )
                        }
                        if (run.input.isNotBlank()) {
                            Text(run.input, style = TsType.body, color = LocalTsColors.current.textSecondary)
                        }
                        JobFactRow("Budget", JobCopy.budget(run.budgetSeconds))
                    }
                }
                if (run.isLive) {
                    TsCard {
                        Row(
                            Modifier.padding(Space.m),
                            horizontalArrangement = Arrangement.spacedBy(Space.s),
                        ) {
                            if (run.isWaiting) {
                                TsAccentButton(
                                    label = if (working) "Working" else "Continue",
                                    enabled = !working,
                                    onClick = onContinue,
                                )
                            }
                            TsSecondaryButton(
                                label = "Stop",
                                icon = ActionIcon.Stop.vector,
                                enabled = !working,
                                onClick = onStop,
                            )
                        }
                    }
                }
                if (run.steps.isNotEmpty()) {
                    Text(
                        "Steps",
                        style = TsType.caption.copy(fontWeight = FontWeight.SemiBold),
                        color = LocalTsColors.current.textTertiary,
                    )
                    val selected = selectedNodeID?.takeIf { id -> run.steps.any { it.nodeID == id } }
                        ?: run.steps.first().nodeID
                    run.steps.forEach { step ->
                        WorkflowStepButton(
                            step = step,
                            isSelected = selected == step.nodeID,
                            onSelect = { onSelectNode(step.nodeID) },
                        )
                    }
                    Text(
                        "Transcript",
                        style = TsType.caption.copy(fontWeight = FontWeight.SemiBold),
                        color = LocalTsColors.current.textTertiary,
                    )
                    TsCard {
                        WorkflowStepTranscript(
                            model = model,
                            peer = peer,
                            runID = run.id,
                            nodeID = selected,
                            live = run.isLive,
                            modifier = Modifier.padding(Space.m),
                        )
                    }
                } else {
                    Text(
                        "Transcript",
                        style = TsType.caption.copy(fontWeight = FontWeight.SemiBold),
                        color = LocalTsColors.current.textTertiary,
                    )
                    TsCard {
                        Text(
                            if (run.isLive) "Waiting for output…" else "No readable output.",
                            style = TsType.body,
                            color = LocalTsColors.current.textSecondary,
                            modifier = Modifier.padding(Space.m),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun WorkflowStepButton(step: WorkflowStep, isSelected: Boolean, onSelect: () -> Unit) {
    val colors = LocalTsColors.current
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(ai.tokenstat.tokenstat.ui.components.cardRadiusDp))
            .background(if (isSelected) colors.rowHighlight else colors.panel)
            .clickable(onClick = onSelect)
            .padding(Space.m),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Canvas(Modifier.size(8.dp)) {
            drawCircle(ai.tokenstat.tokenstat.ui.marks.RunOutcome.tint(step.status, colors))
        }
        Text(
            step.title.ifBlank { step.kind },
            style = TsType.subheadline.copy(fontWeight = FontWeight.Medium),
            color = colors.textPrimary,
            modifier = Modifier.weight(1f),
        )
        JobStatusPill(step.status, WorkflowRunRecord.label(step.status))
    }
}

@Composable
private fun WorkflowStepTranscript(
    model: AppViewModel,
    peer: String,
    runID: String,
    nodeID: String,
    live: Boolean,
    modifier: Modifier = Modifier,
) {
    var text by remember(runID, nodeID) { mutableStateOf<String?>(null) }
    ForegroundEffect(peer, runID, nodeID, live) {
        var offset = 0L
        val buffer = StringBuilder()
        do {
            val chunk = runCatching {
                model.workspaceSection(peer, "workflow.transcript", buildJsonObject {
                    put("id", runID)
                    put("nodeId", nodeID)
                    put("offset", offset)
                }) as JsonObject
            }.getOrElse { failure ->
                if (failure is kotlinx.coroutines.CancellationException) throw failure
                text = buffer.toString().ifEmpty { "Output is unavailable right now." }
                return@ForegroundEffect
            }
            buffer.append(chunk.optStr("text").orEmpty())
            if (buffer.length > 256 * 1024) buffer.delete(0, buffer.length - 256 * 1024)
            text = buffer.toString()
            offset = chunk.optLong("nextOffset") ?: break
            if (live) delay(1_000)
        } while (live)
    }
    Text(
        text ?: "Loading…",
        style = TsType.mono(12),
        color = LocalTsColors.current.textPrimary,
        modifier = modifier,
    )
    if (text != null && text!!.isBlank()) {
        Text(
            if (live) "Waiting for output…" else "No readable output.",
            style = TsType.body,
            color = LocalTsColors.current.textSecondary,
            modifier = modifier,
        )
    }
}

/// A client-chosen graph id. Retries reuse the same id and the check reads
/// it back, so a lost creation reply can never mint a second workflow.
fun newWorkflowID(): String = "wf-" + UUID.randomUUID().toString().lowercase()

/// Same content, ignoring run metadata the host owns. Port of the
/// `graphMatches` recovery comparison.
fun workflowContentMatches(left: WorkflowGraph, right: WorkflowGraph): Boolean =
    left.name == right.name &&
        left.workspaceID == right.workspaceID &&
        left.scope == right.scope &&
        left.schedule == right.schedule &&
        left.budgetSeconds == right.budgetSeconds &&
        left.enabled == right.enabled &&
        left.nodes == right.nodes &&
        left.edges == right.edges &&
        left.extra == right.extra
