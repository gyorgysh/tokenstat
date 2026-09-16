// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workflows

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.automations.AutomationJob
import ai.tokenstat.tokenstat.ui.automations.AutomationQueue
import ai.tokenstat.tokenstat.ui.automations.HostScheduleClock
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.BrandToggleChip
import ai.tokenstat.tokenstat.ui.components.EmptyState
import ai.tokenstat.tokenstat.ui.components.SectionLabel
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.logic.HostContracts
import ai.tokenstat.tokenstat.ui.logic.RelativeClock
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

/// The workflows workbench: list with live runs, New/Edit/Delete,
/// recipe/blank/draft-from-prompt starters, run/stop/continue, and complete
/// run history with per-step transcripts.
///
/// Ports `ClientWorkflowWorkspace` and `ClientWorkflowBoard` (phone step
/// list lives in the editor). Saves are `workflow.edit` with the baseline
/// revision on protocol 22+ hosts, `workflow.update` below that, with the
/// re-read-and-compare recovery instead of a blind retry.
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
    var creating by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<WorkflowGraph?>(null) }
    var historyGraph by remember { mutableStateOf<String?>(null) }
    var runInput by remember { mutableStateOf<WorkflowGraph?>(null) }

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

    LaunchedEffect(peer) { load() }
    val anyLive = runs.any { it.isLive }
    LaunchedEffect(anyLive, peer) {
        if (!anyLive) return@LaunchedEffect
        while (true) {
            delay(3_000)
            if (!working && !loading) load()
        }
    }

    val scoped = remember(graphs, workspaceID) {
        graphs.filter { it.workspaceID == workspaceID || (it.scope == WorkflowScope.GLOBAL && workspaceID.isEmpty()) }
    }
    val timezone = HostScheduleClock.resolved(queue.timezone)

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(Modifier.fillMaxSize().padding(Space.m)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Workflows", style = TsType.cardTitle, color = LocalTsColors.current.textPrimary)
                    Text(folderName.ifBlank { hostLabel }, style = TsType.caption, color = LocalTsColors.current.textSecondary)
                }
                IconButton(onClick = { creating = true }) {
                    Icon(ActionIcon.Create.vector, "New workflow", tint = LocalTsColors.current.accent)
                }
                IconButton(onClick = onDismiss) {
                    Icon(ActionIcon.Dismiss.vector, "Close", tint = LocalTsColors.current.controlGlyph)
                }
            }
            if (!supportsEdits) {
                Text(
                    "Update $hostLabel's tokenstat to save workflows from here. Below protocol 22 every save is last-write-wins.",
                    style = TsType.caption,
                    color = LocalTsColors.current.textSecondary,
                )
            }
            if (error != null) {
                Banner(error!!, BannerSeverity.DANGER)
                TsSecondaryButton(label = "Reload", small = true, onClick = { scope.launch { load() } })
            }
            if (notice != null) {
                Text(notice!!, style = TsType.caption, color = LocalTsColors.current.textSecondary)
            }
            if (loading && !loaded) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    CircularProgressIndicator()
                    Text("Loading workflows", color = LocalTsColors.current.textSecondary)
                }
            }
            PullToRefreshBox(isRefreshing = loading && loaded, onRefresh = { scope.launch { load() } }, modifier = Modifier.weight(1f)) {
                LazyColumn(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(Space.s)) {
                    if (loaded && scoped.isEmpty()) {
                        item {
                            EmptyState(
                                ActionIcon.Plan.vector,
                                "No workflows yet",
                                "A workflow chains agent steps, commands and checks into one run.",
                                art = { EmptyArt(EmptyArtKind.Workflows) },
                            )
                        }
                    }
                    items(scoped, key = { it.id }) { graph ->
                        val graphRuns = runs.filter { it.workflowID == graph.id }
                        val live = graphRuns.firstOrNull { it.isLive }
                        TsCard {
                            Column(Modifier.padding(Space.m), verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Column(Modifier.weight(1f)) {
                                        Text(graph.name.ifBlank { "Untitled" }, style = TsType.body.copy(fontWeight = FontWeight.SemiBold), color = LocalTsColors.current.textPrimary)
                                        Text(
                                            HostScheduleClock.listSubtitle(graph.schedule.summary, graph.nextRunAtMs, graph.enabled, graph.schedule.repeats, queue.timezone),
                                            style = TsType.caption,
                                            color = LocalTsColors.current.textSecondary,
                                        )
                                    }
                                    if (live != null) {
                                        Text(
                                            live.endedLabel,
                                            style = TsType.caption.copy(fontWeight = FontWeight.SemiBold),
                                            color = LocalTsColors.current.accent,
                                        )
                                    }
                                }
                                Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                                    if (live?.isWaiting == true) {
                                        TsAccentButton(label = "Continue", small = true, enabled = !working, onClick = { scope.launch { continueRun(live) } })
                                        TsSecondaryButton(label = "Stop", icon = ActionIcon.Stop.vector, small = true, enabled = !working, onClick = { scope.launch { stop(live) } })
                                    } else if (live != null) {
                                        TsSecondaryButton(label = "Stop", icon = ActionIcon.Stop.vector, small = true, enabled = !working, onClick = { scope.launch { stop(live) } })
                                    } else {
                                        TsAccentButton(label = "Run", icon = ActionIcon.Run.vector, small = true, enabled = !working, onClick = { runInput = graph })
                                    }
                                    TsSecondaryButton(label = "Edit", small = true, onClick = { editing = graph })
                                    TsSecondaryButton(
                                        label = if (historyGraph == graph.id) "Hide runs" else "Runs",
                                        icon = ActionIcon.History.vector,
                                        small = true,
                                        onClick = { historyGraph = if (historyGraph == graph.id) null else graph.id },
                                    )
                                }
                                if (historyGraph == graph.id) {
                                    WorkflowRunHistory(
                                        runs = graphRuns,
                                        model = model,
                                        peer = peer,
                                        hostLabel = hostLabel,
                                        working = working,
                                        onStop = { scope.launch { stop(it) } },
                                        onContinue = { scope.launch { continueRun(it) } },
                                    )
                                }
                            }
                        }
                    }
                }
            }
            Text(
                timezone?.let { HostScheduleClock.timesCaption(hostLabel, queue.timezone) } ?: "",
                style = TsType.caption,
                color = LocalTsColors.current.textSecondary,
            )
        }
    }
    if (creating) {
        WorkflowEditorDialog(
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
            onDismiss = { creating = false },
        )
    }
    val editingGraph = editing
    if (editingGraph != null) {
        WorkflowEditorDialog(
            model = model,
            peer = peer,
            hostLabel = hostLabel,
            protocol = protocol,
            workspaceID = workspaceID,
            folderName = folderName,
            existing = editingGraph,
            backends = backends,
            backendRefs = backends.map { BackendRef(it.id, it.label, it.models, it.efforts) },
            automations = automations,
            folders = folders,
            defaultBudget = queue.defaultBudgetSeconds,
            timezone = timezone.orEmpty(),
            onSaved = { scope.launch { load() } },
            onDismiss = { editing = null },
        )
    }
    val inputGraph = runInput
    if (inputGraph != null) {
        var input by remember(inputGraph.id) { mutableStateOf("") }
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { runInput = null },
            title = { Text("Run ${inputGraph.name}") },
            text = {
                OutlinedTextField(input, { input = it }, modifier = Modifier.fillMaxWidth(), label = { Text("Starting prompt") }, minLines = 3)
            },
            confirmButton = {
                TsAccentButton(label = "Run", small = true, onClick = {
                    runInput = null
                    scope.launch { run(inputGraph, input) }
                })
            },
            dismissButton = { TextButton(onClick = { runInput = null }) { Text("Cancel") } },
        )
    }
}

/// Complete run history for one workflow, live-first. Steps carry their
/// status and per-step transcripts; a waiting run offers Continue.
@Composable
fun WorkflowRunHistory(
    runs: List<WorkflowRunRecord>,
    model: AppViewModel,
    peer: String,
    hostLabel: String,
    working: Boolean,
    onStop: (WorkflowRunRecord) -> Unit,
    onContinue: (WorkflowRunRecord) -> Unit,
) {
    var shown by remember { mutableStateOf(20) }
    var openSteps by remember { mutableStateOf<String?>(null) }
    val ordered = remember(runs) {
        RunHistory.ordered(runs.map { RunRef(it.id, it.startedAtMs, it.isLive) })
    }
    val byID = remember(runs) { runs.associateBy { it.id } }
    val page = ordered.take(maxOf(0, shown)).mapNotNull { byID[it.id] }
    val remaining = RunHistory.remaining(runs.size, shown)
    Column(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
        SectionLabel("Runs", runs.size)
        page.forEach { run ->
            TsCard {
                Column(Modifier.padding(Space.m), verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            run.endedLabel,
                            style = TsType.body.copy(fontWeight = FontWeight.SemiBold),
                            color = if (run.status == "error") LocalTsColors.current.danger else LocalTsColors.current.textPrimary,
                            modifier = Modifier.weight(1f),
                        )
                        Text(
                            RelativeClock.abbreviated(run.startedAtMs),
                            style = TsType.caption,
                            color = LocalTsColors.current.textSecondary,
                        )
                    }
                    if (run.input.isNotBlank()) {
                        Text(run.input, style = TsType.caption, color = LocalTsColors.current.textSecondary, maxLines = 3)
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                        if (run.isWaiting) {
                            TsAccentButton(label = "Continue", small = true, enabled = !working, onClick = { onContinue(run) })
                        }
                        if (run.isLive) {
                            TsSecondaryButton(label = "Stop", icon = ActionIcon.Stop.vector, small = true, enabled = !working, onClick = { onStop(run) })
                        }
                        TsSecondaryButton(
                            label = if (openSteps == run.id) "Hide steps" else "Steps",
                            small = true,
                            onClick = { openSteps = if (openSteps == run.id) null else run.id },
                        )
                    }
                    if (openSteps == run.id) {
                        run.steps.forEach { step ->
                            WorkflowStepRow(model = model, peer = peer, runID = run.id, step = step, live = run.isLive)
                        }
                        if (run.steps.isEmpty()) {
                            Text("No steps recorded yet.", style = TsType.caption, color = LocalTsColors.current.textSecondary)
                        }
                    }
                }
            }
        }
        if (remaining > 0) {
            TsSecondaryButton(label = "Earlier runs ($remaining)", small = true, onClick = { shown += 20 })
        }
    }
}

@Composable
private fun WorkflowStepRow(model: AppViewModel, peer: String, runID: String, step: WorkflowStep, live: Boolean) {
    var open by remember(runID, step.nodeID) { mutableStateOf(false) }
    var transcript by remember(runID, step.nodeID) { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    Column(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(
                    step.title.ifBlank { step.nodeID },
                    style = TsType.body.copy(fontWeight = FontWeight.Medium),
                    color = LocalTsColors.current.textPrimary,
                )
                Text(
                    WorkflowRunRecord.label(step.status),
                    style = TsType.caption,
                    color = LocalTsColors.current.textSecondary,
                )
            }
            TextButton(onClick = {
                open = !open
                if (open && transcript == null) {
                    scope.launch {
                        transcript = runCatching {
                            model.workspaceSection(peer, "workflow.transcript", buildJsonObject {
                                put("id", runID)
                                put("nodeId", step.nodeID)
                                put("offset", 0)
                            }) as JsonObject
                        }.getOrNull()?.optStr("text") ?: "No readable output."
                    }
                }
            }) { Text(if (open) "Hide" else "Output") }
        }
        if (open) {
            Text(
                transcript ?: "Loading…",
                style = TsType.mono(12),
                color = LocalTsColors.current.textPrimary,
            )
            if (step.output.isNotBlank() && transcript != step.output) {
                Text(step.output, style = TsType.caption, color = LocalTsColors.current.textSecondary)
            }
        }
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
