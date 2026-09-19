// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.automations

import ai.tokenstat.tokenstat.ui.components.ForegroundEffect
import ai.tokenstat.tokenstat.ui.chrome.OwnSectionHeader

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.BrandToggleChip
import ai.tokenstat.tokenstat.ui.components.ConcurrentChips
import ai.tokenstat.tokenstat.ui.components.EmptyState
import ai.tokenstat.tokenstat.ui.components.TimeLimitChips
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsSearchField
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.logic.HostContracts
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import ai.tokenstat.tokenstat.ui.marks.CadenceGlyph
import ai.tokenstat.tokenstat.ui.marks.EmptyArt
import ai.tokenstat.tokenstat.ui.marks.EmptyArtKind
import ai.tokenstat.tokenstat.ui.marks.SlotGauge
import ai.tokenstat.tokenstat.ui.tasks.BackendRef
import ai.tokenstat.tokenstat.ui.tasks.RunHistory
import ai.tokenstat.tokenstat.ui.tasks.RunRef
import ai.tokenstat.tokenstat.ui.tasks.TaskOperations
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

private sealed interface AutomationRoute {
    data object List : AutomationRoute
    data class Detail(val jobID: String) : AutomationRoute
    data class History(val jobID: String) : AutomationRoute
    data class Run(val jobID: String, val runID: String) : AutomationRoute
    data object Create : AutomationRoute
    data class Edit(val jobID: String) : AutomationRoute
    data object Queue : AutomationRoute
}

private sealed interface AutomationConfirm {
    data class Run(val jobID: String) : AutomationConfirm
    data class Stop(val runID: String) : AutomationConfirm
    data class Delete(val jobID: String) : AutomationConfirm
}

@Composable
fun AutomationsDialog(
    model: AppViewModel,
    peer: String,
    hostLabel: String,
    protocol: Long?,
    workspaceID: String,
    folderName: String,
    onDismiss: () -> Unit,
) {
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        AutomationsScreen(
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

/// The automations workbench as full pages: list, detail, history, run,
/// the editor, and the host scheduler. Ports `ClientAutomationWorkspace`
/// (phone list), the detail, history and run views, the queue editor, and
/// the `ClientAutomationSession` operation rules.
///
/// Create-once and run-once receipts where the host offers them (protocol
/// 21+), revision-checked `automation.edit` saves with the conflict flow,
/// and plain `create`/`run`/`update` below that.
@Composable
fun AutomationsScreen(
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
    val supportsReceipts = HostContracts.supportsAutomationReceipts(protocol)
    var jobs by remember { mutableStateOf<List<AutomationJob>>(emptyList()) }
    var runs by remember { mutableStateOf<List<AutomationRun>>(emptyList()) }
    var backends by remember { mutableStateOf<List<BackendRef>>(emptyList()) }
    var queue by remember { mutableStateOf(AutomationQueue()) }
    var loaded by remember { mutableStateOf(false) }
    var loading by remember { mutableStateOf(true) }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var notice by remember { mutableStateOf<String?>(null) }
    var stack by remember { mutableStateOf(listOf<AutomationRoute>(AutomationRoute.List)) }
    var search by remember { mutableStateOf("") }
    var shownRuns by remember { mutableStateOf(mapOf<String, Int>()) }
    var pendingLaunches by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
    var retryableLaunches by remember { mutableStateOf(setOf<String>()) }
    var queueDraft by remember { mutableStateOf<QueueDraft?>(null) }
    var justSavedQueue by remember { mutableStateOf(false) }
    var confirm by remember { mutableStateOf<AutomationConfirm?>(null) }

    val route = stack.last()
    fun push(next: AutomationRoute) {
        stack = (stack + next).takeLast(8)
    }
    fun pop() {
        stack = if (stack.size > 1) stack.dropLast(1) else stack
    }
    fun dropJob(jobID: String) {
        stack = (listOf(AutomationRoute.List) + stack.filter {
            when (it) {
                is AutomationRoute.List -> false
                is AutomationRoute.Detail -> it.jobID != jobID
                is AutomationRoute.History -> it.jobID != jobID
                is AutomationRoute.Run -> it.jobID != jobID
                is AutomationRoute.Create -> true
                is AutomationRoute.Edit -> it.jobID != jobID
                is AutomationRoute.Queue -> true
            }
        }).distinct()
    }

    suspend fun load() {
        loading = true
        runCatching {
            model.workspaceSection(peer, "automation.list", buildJsonObject {})
        }.onSuccess { element ->
            jobs = ((element as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()).map(AutomationJob::parse)
            loaded = true
            error = null
        }.onFailure {
            error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel)
        }
        runCatching {
            model.workspaceSection(peer, "automation.runs", buildJsonObject {})
        }.onSuccess { element ->
            runs = ((element as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()).map(AutomationRun::parse)
        }
        runCatching { model.workspaceSection(peer, "automation.backends", buildJsonObject {}) }
            .onSuccess { element ->
                backends = ((element as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()).map(BackendRef::parse)
            }
        runCatching { model.workspaceSection(peer, "automation.queue", buildJsonObject {}) }
            .onSuccess { element ->
                queue = AutomationQueue.parse(element as? JsonObject)
                if (queueDraft == null) queueDraft = QueueDraft.fromQueue(queue)
            }
        loading = false
    }

    suspend fun toggle(job: AutomationJob) {
        if (working) return
        working = true
        runCatching {
            model.workspaceSection(peer, if (job.enabled) "automation.disable" else "automation.enable", buildJsonObject {
                put("id", job.id)
            })
        }.onSuccess { load() }
            .onFailure { error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
        working = false
    }

    suspend fun confirmRun(outcome: AutomationRunOutcome, job: AutomationJob): Boolean {
        if (outcome.operationID != pendingLaunches[job.id]) {
            error = "The computer returned a different run. Check this job again."
            return false
        }
        if (outcome.run == null) {
            error = "The computer accepted this request but has not recorded its run yet. Check again or retry the same request."
            return false
        }
        pendingLaunches = pendingLaunches - job.id
        retryableLaunches = retryableLaunches - job.id
        notice = "Started ${job.name}."
        error = null
        load()
        return true
    }

    suspend fun submitLaunch(job: AutomationJob, operationID: String) {
        working = true
        try {
            val element = model.workspaceSection(peer, "automation.runOnce", buildJsonObject {
                put("id", job.id)
                put("operationId", operationID)
            })
            confirmRun(AutomationRunOutcome.parse(element as JsonObject), job)
        } catch (e: Exception) {
            val receipt = runCatching {
                model.workspaceSection(peer, "automation.runReceipt", buildJsonObject { put("operationId", operationID) })
            }.getOrNull()
            if (receipt != null && receipt !is JsonNull) {
                confirmRun(AutomationRunOutcome.parse(receipt as JsonObject), job)
                return
            }
            retryableLaunches = retryableLaunches + job.id
            error = TunnelCopy.display(
                "The computer did not confirm this run. Check it before starting another. ${e.message ?: ""}".trim(),
                hostLabel,
            )
        } finally {
            working = false
        }
    }

    suspend fun run(job: AutomationJob) {
        if (working) return
        if (!supportsReceipts) {
            working = true
            try {
                model.workspaceSection(peer, "automation.run", buildJsonObject { put("id", job.id) })
                notice = "Started ${job.name}."
                error = null
                load()
            } catch (e: Exception) {
                error = TunnelCopy.display(e.message ?: "The request failed.", hostLabel)
            } finally {
                working = false
            }
            return
        }
        val operationID = pendingLaunches[job.id] ?: TaskOperations.automationRunID()
        pendingLaunches = pendingLaunches + (job.id to operationID)
        retryableLaunches = retryableLaunches - job.id
        submitLaunch(job, operationID)
    }

    suspend fun checkLaunch(job: AutomationJob) {
        val operationID = pendingLaunches[job.id] ?: return
        if (working) return
        working = true
        try {
            val element = model.workspaceSection(peer, "automation.runReceipt", buildJsonObject {
                put("operationId", operationID)
            })
            if (element is JsonNull) {
                retryableLaunches = retryableLaunches + job.id
                error = null
                notice = "The computer has no run receipt yet. Retry run uses the same request."
            } else {
                confirmRun(AutomationRunOutcome.parse(element as JsonObject), job)
            }
        } catch (e: Exception) {
            error = TunnelCopy.display(e.message ?: "The request failed.", hostLabel)
        } finally {
            working = false
        }
    }

    suspend fun retryLaunch(job: AutomationJob) {
        val operationID = pendingLaunches[job.id] ?: return
        if (working || !retryableLaunches.contains(job.id)) return
        retryableLaunches = retryableLaunches - job.id
        submitLaunch(job, operationID)
    }

    suspend fun stop(run: AutomationRun) {
        if (working) return
        working = true
        runCatching {
            model.workspaceSection(peer, "automation.kill", buildJsonObject { put("id", run.id) })
        }.onSuccess {
            notice = "Stopped ${run.name}."
            error = null
            load()
        }.onFailure {
            error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel)
        }
        working = false
    }

    suspend fun remove(job: AutomationJob) {
        if (working) return
        working = true
        runCatching {
            model.workspaceSection(peer, "automation.remove", buildJsonObject { put("id", job.id) })
        }.onSuccess {
            dropJob(job.id)
            notice = "Deleted ${job.name}."
            error = null
            load()
        }.onFailure {
            error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel)
        }
        working = false
    }

    suspend fun saveQueue(budget: Long, max: Long) {
        if (working) return
        working = true
        runCatching {
            model.workspaceSection(peer, "automation.setQueue", buildJsonObject {
                put("defaultBudgetSeconds", budget)
                put("maxConcurrent", max)
            }) as JsonObject
        }.onSuccess { element ->
            queue = AutomationQueue.parse(element)
            queueDraft = QueueDraft.fromQueue(queue)
            justSavedQueue = true
            notice = "Scheduler saved."
            error = null
        }.onFailure {
            justSavedQueue = false
            error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel)
        }
        working = false
    }

    LaunchedEffect(peer) { load() }
    val anyLive = runs.any { it.isRunning }
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

    val scoped = remember(jobs, workspaceID) { jobs.filter { it.workspaceID == workspaceID } }
    val timezone = HostScheduleClock.resolved(queue.timezone).orEmpty()
    val folderCaption = folderName.ifBlank { hostLabel }

    Column(
        Modifier
            .fillMaxSize()
            .background(LocalTsColors.current.background)
            .padding(Space.m),
    ) {
        when (route) {
            is AutomationRoute.List -> AutomationListPage(
                scoped = scoped,
                runs = runs,
                queue = queue,
                loaded = loaded,
                loading = loading,
                working = working,
                error = error,
                notice = notice,
                search = search,
                hostLabel = hostLabel,
                folderName = folderName,
                folderCaption = folderCaption,
                queueTimezone = queue.timezone,
                onSearch = { search = it },
                onReload = { scope.launch { load() } },
                onBack = onBack,
                onOpen = { push(AutomationRoute.Detail(it)) },
                onCreate = { push(AutomationRoute.Create) },
                onEdit = { push(AutomationRoute.Edit(it)) },
                onDelete = { confirm = AutomationConfirm.Delete(it) },
                onQueue = { push(AutomationRoute.Queue) },
            )
            is AutomationRoute.Detail -> {
                val job = scoped.firstOrNull { it.id == route.jobID }
                AutomationDetailPage(
                    job = job,
                    loaded = loaded,
                    loading = loading,
                    working = working,
                    error = error,
                    notice = notice,
                    runs = runs.filter { it.jobId == route.jobID },
                    hostLabel = hostLabel,
                    folderName = folderName,
                    queueTimezone = queue.timezone,
                    hasPendingLaunch = pendingLaunches.containsKey(route.jobID),
                    canRetryLaunch = retryableLaunches.contains(route.jobID),
                    onReload = { scope.launch { load() } },
                    onBack = ::pop,
                    onEdit = { push(AutomationRoute.Edit(route.jobID)) },
                    onDelete = { confirm = AutomationConfirm.Delete(route.jobID) },
                    onRun = { confirm = AutomationConfirm.Run(route.jobID) },
                    onStop = { confirm = AutomationConfirm.Stop(it) },
                    onCheckRun = { j -> scope.launch { checkLaunch(j) } },
                    onRetryRun = { j -> scope.launch { retryLaunch(j) } },
                    onToggle = { j -> scope.launch { toggle(j) } },
                    onHistory = { push(AutomationRoute.History(route.jobID)) },
                    onRunOpen = { push(AutomationRoute.Run(route.jobID, it)) },
                )
            }
            is AutomationRoute.History -> AutomationHistoryPage(
                job = scoped.firstOrNull { it.id == route.jobID },
                runs = runs.filter { it.jobId == route.jobID },
                loaded = loaded,
                loading = loading,
                hostLabel = hostLabel,
                queueTimezone = queue.timezone,
                shown = shownRuns[route.jobID] ?: RunHistory.PAGE_SIZE,
                onMore = { shownRuns = shownRuns + (route.jobID to ((shownRuns[route.jobID] ?: RunHistory.PAGE_SIZE) + RunHistory.PAGE_SIZE)) },
                onReload = { scope.launch { load() } },
                onBack = ::pop,
                onRunOpen = { push(AutomationRoute.Run(route.jobID, it)) },
            )
            is AutomationRoute.Run -> {
                val run = runs.firstOrNull { it.id == route.runID }
                AutomationRunPage(
                    model = model,
                    peer = peer,
                    run = run,
                    liveRunID = runs.firstOrNull { it.jobId == route.jobID && it.isRunning }?.id,
                    loaded = loaded,
                    loading = loading,
                    working = working,
                    error = error,
                    hostLabel = hostLabel,
                    queueTimezone = queue.timezone,
                    onReload = { scope.launch { load() } },
                    onBack = ::pop,
                    onStop = { confirm = AutomationConfirm.Stop(route.runID) },
                )
            }
            is AutomationRoute.Create -> AutomationEditorScreen(
                model = model,
                peer = peer,
                hostLabel = hostLabel,
                protocol = protocol,
                workspaceID = workspaceID,
                folderName = folderName,
                existing = null,
                backends = backends,
                defaultBudget = queue.defaultBudgetSeconds,
                timezone = timezone,
                onSaved = { scope.launch { load() } },
                onBack = ::pop,
            )
            is AutomationRoute.Edit -> AutomationEditorScreen(
                model = model,
                peer = peer,
                hostLabel = hostLabel,
                protocol = protocol,
                workspaceID = workspaceID,
                folderName = folderName,
                existing = scoped.firstOrNull { it.id == route.jobID },
                backends = backends,
                defaultBudget = queue.defaultBudgetSeconds,
                timezone = timezone,
                onSaved = { scope.launch { load() } },
                onBack = ::pop,
            )
            is AutomationRoute.Queue -> SchedulerPage(
                queue = queue,
                draft = queueDraft,
                runningCount = runs.count { it.isRunning },
                loaded = loaded,
                working = working,
                error = error,
                notice = notice,
                justSaved = justSavedQueue,
                hostLabel = hostLabel,
                folderName = folderName,
                queueTimezone = queue.timezone,
                onDraft = { queueDraft = it; justSavedQueue = false },
                onReload = { scope.launch { load() } },
                onBack = ::pop,
                onSave = { budget, max -> scope.launch { saveQueue(budget, max) } },
            )
        }
    }
    val pending = confirm
    if (pending != null) {
        val job = jobs.firstOrNull {
            it.id == when (pending) {
                is AutomationConfirm.Run -> pending.jobID
                is AutomationConfirm.Delete -> pending.jobID
                is AutomationConfirm.Stop -> runs.firstOrNull { item -> item.id == pending.runID }?.jobId
            }
        }
        val targetRun = if (pending is AutomationConfirm.Stop) runs.firstOrNull { it.id == pending.runID } else null
        val name = job?.name?.ifBlank { "this job" } ?: "this job"
        val place = folderName.ifBlank { "this folder" }
        when (pending) {
            is AutomationConfirm.Run -> if (job != null) JobConfirmDialog(
                title = "Run $name?",
                message = JobCopy.run(name, place, hostLabel),
                confirmLabel = "Run",
                onConfirm = { scope.launch { run(job) } },
                onDismiss = { confirm = null },
            )
            is AutomationConfirm.Stop -> if (targetRun != null) JobConfirmDialog(
                title = "Stop $name?",
                message = JobCopy.stop(name, place, hostLabel),
                confirmLabel = "Stop",
                destructive = true,
                onConfirm = { scope.launch { stop(targetRun) } },
                onDismiss = { confirm = null },
            )
            is AutomationConfirm.Delete -> if (job != null) JobConfirmDialog(
                title = "Delete $name?",
                message = "The schedule goes with it. Runs it already produced stay.",
                confirmLabel = "Delete",
                destructive = true,
                onConfirm = { scope.launch { remove(job) } },
                onDismiss = { confirm = null },
            )
        }
    }
}

private fun orderedAutomationRuns(runs: List<AutomationRun>): List<AutomationRun> {
    val ordered = RunHistory.ordered(runs.map { RunRef(it.id, it.startedAtMs, it.isRunning) })
    val byID = runs.associateBy { it.id }
    return ordered.mapNotNull { byID[it.id] }
}

/// The library: search, the scheduler card, the summary, and one row per
/// job. Port of the `ClientAutomationWorkspace` phone list.
@Composable
private fun AutomationListPage(
    scoped: List<AutomationJob>,
    runs: List<AutomationRun>,
    queue: AutomationQueue,
    loaded: Boolean,
    loading: Boolean,
    working: Boolean,
    error: String?,
    notice: String?,
    search: String,
    hostLabel: String,
    folderName: String,
    folderCaption: String,
    queueTimezone: String?,
    onSearch: (String) -> Unit,
    onReload: () -> Unit,
    onBack: () -> Unit,
    onOpen: (String) -> Unit,
    onCreate: () -> Unit,
    onEdit: (String) -> Unit,
    onDelete: (String) -> Unit,
    onQueue: () -> Unit,
) {
    val filtered = remember(scoped, search) { scoped.filter { jobMatchesQuery(it, search) } }
    val enabledCount = remember(scoped) { scoped.count { it.enabled } }
    val runningCount = remember(runs, scoped) {
        val ids = scoped.map { it.id }.toSet()
        runs.count { it.isRunning && it.jobId in ids }
    }
    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(Space.s)) {
        JobScreenHeader(
            title = "Automations",
            subtitle = folderCaption,
            onBack = onBack,
            actions = {
                IconButton(onClick = onCreate) {
                    Icon(ActionIcon.Create.vector, "New automation", tint = LocalTsColors.current.accent)
                }
            },
        )
        if (error != null) {
            Banner(error, BannerSeverity.DANGER)
            TsSecondaryButton(label = "Reload", small = true, onClick = onReload)
        }
        if (notice != null) {
            Text(notice, style = TsType.caption, color = LocalTsColors.current.textSecondary)
        }
        TsSearchField(prompt = "Search automations", query = search, onQueryChange = onSearch)
        if (loading && !loaded) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                CircularProgressIndicator()
                Text("Loading automations", color = LocalTsColors.current.textSecondary)
            }
        }
        PullToRefreshBox(isRefreshing = loading && loaded, onRefresh = onReload, modifier = Modifier.weight(1f)) {
            LazyColumn(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(Space.s)) {
                if (loaded) {
                    item(key = "scheduler") {
                        SchedulerCard(
                            hostLabel = hostLabel,
                            folderName = folderName,
                            queue = queue,
                            onOpen = onQueue,
                        )
                    }
                    if (scoped.isNotEmpty()) {
                        item(key = "summary") {
                            Text(
                                automationListSummary(enabledCount, runningCount),
                                style = TsType.caption,
                                color = LocalTsColors.current.textSecondary,
                            )
                        }
                    }
                }
                if (loaded && scoped.isEmpty()) {
                    item {
                        EmptyState(
                            ActionIcon.Scheduled.vector,
                            "Nothing scheduled here",
                            "Create a job for this folder. It runs on the connected computer.",
                            art = { EmptyArt(EmptyArtKind.Automations) },
                            action = {
                                TsAccentButton(label = "New automation", icon = ActionIcon.Create.vector, small = true, onClick = onCreate)
                            },
                        )
                    }
                } else if (loaded && filtered.isEmpty()) {
                    item {
                        Text(
                            "No matching automations",
                            style = TsType.body,
                            color = LocalTsColors.current.textSecondary,
                        )
                    }
                }
                items(filtered, key = { it.id }) { job ->
                    AutomationJobRow(
                        job = job,
                        subtitle = HostScheduleClock.listSubtitle(
                            job.schedule.summary,
                            job.nextRunAtMs,
                            job.enabled,
                            job.schedule.repeats,
                            queueTimezone,
                        ),
                        isLive = runs.any { it.jobId == job.id && it.isRunning },
                        working = working,
                        onOpen = { onOpen(job.id) },
                        onEdit = { onEdit(job.id) },
                        onDelete = { onDelete(job.id) },
                    )
                }
            }
        }
    }
}

/// Library row for host-wide scheduler defaults. The list may be one
/// folder. The copy must not be. Port of `ClientSchedulerCard`.
@Composable
private fun SchedulerCard(hostLabel: String, folderName: String, queue: AutomationQueue?, onOpen: () -> Unit) {
    val colors = LocalTsColors.current
    TsCard {
        Row(
            Modifier
                .fillMaxWidth()
                .clickable(onClick = onOpen)
                .padding(Space.m),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Space.s),
        ) {
            Icon(ActionIcon.Scheduled.vector, null, tint = colors.accent, modifier = Modifier.size(28.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(
                    "Scheduler",
                    style = TsType.subheadline.copy(fontWeight = FontWeight.Medium),
                    color = colors.textPrimary,
                )
                Text(
                    if (queue == null) "How queued jobs run on this computer"
                    else QueueCopy.summary(queue.defaultBudgetSeconds, queue.maxConcurrent),
                    style = TsType.caption,
                    color = colors.textSecondary,
                )
                Text(
                    QueueCopy.scope(hostLabel, folderName),
                    style = TsType.caption,
                    color = colors.textSecondary,
                )
            }
        }
    }
}

/// A job as a name, one quiet line, and whether it is going.
/// Port of `ClientJobRow`.
@Composable
private fun AutomationJobRow(
    job: AutomationJob,
    subtitle: String,
    isLive: Boolean,
    working: Boolean,
    onOpen: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    val colors = LocalTsColors.current
    var menu by remember { mutableStateOf(false) }
    val isPaused = !job.enabled && job.schedule.repeats
    TsCard {
        Row(
            Modifier
                .fillMaxWidth()
                .clickable(onClick = onOpen)
                .padding(Space.m),
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(Space.s),
        ) {
            Box(Modifier.padding(top = 2.dp)) {
                CadenceGlyph(
                    kind = job.schedule.kind.name.lowercase(),
                    weekdays = job.schedule.weekdays,
                    weekday = job.schedule.weekday,
                    enabled = job.enabled,
                )
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    job.name.ifBlank { "Untitled" },
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
                        Icon(ActionIcon.More.vector, "Automation actions", tint = colors.controlGlyph)
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

/// One scheduled job on a phone: the prompt, Run / Stop, pause.
/// Port of `ClientAutomationDetailView`.
@Composable
private fun AutomationDetailPage(
    job: AutomationJob?,
    loaded: Boolean,
    loading: Boolean,
    working: Boolean,
    error: String?,
    notice: String?,
    runs: List<AutomationRun>,
    hostLabel: String,
    folderName: String,
    queueTimezone: String?,
    hasPendingLaunch: Boolean,
    canRetryLaunch: Boolean,
    onReload: () -> Unit,
    onBack: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
    onRun: () -> Unit,
    onStop: (String) -> Unit,
    onCheckRun: (AutomationJob) -> Unit,
    onRetryRun: (AutomationJob) -> Unit,
    onToggle: (AutomationJob) -> Unit,
    onHistory: () -> Unit,
    onRunOpen: (String) -> Unit,
) {
    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(Space.s)) {
        JobScreenHeader(
            title = job?.name?.ifBlank { "Automation" } ?: "Automation",
            subtitle = folderName.ifBlank { hostLabel },
            onBack = onBack,
            actions = {
                if (job != null) {
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
                if (job == null) {
                    if (loaded) {
                        JobGoneCard("This job is gone", "It is not in the folder any more.")
                    } else {
                        CircularProgressIndicator()
                    }
                    return@Column
                }
                val live = runs.firstOrNull { it.isRunning }
                TsCard {
                    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                            CadenceGlyph(
                                kind = job.schedule.kind.name.lowercase(),
                                weekdays = job.schedule.weekdays,
                                weekday = job.schedule.weekday,
                                enabled = job.enabled,
                            )
                            Text(hostLabel, style = TsType.caption, color = LocalTsColors.current.textSecondary)
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(Space.m)) {
                            JobFactRow("Backend", job.backend, Modifier.weight(1f))
                            JobFactRow("Schedule", job.schedule.summary, Modifier.weight(1f))
                        }
                        if (!job.model.isNullOrEmpty()) {
                            JobFactRow("Model", job.model!!)
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(Space.m)) {
                            JobFactRow("Budget", JobCopy.budget(job.budgetSeconds), Modifier.weight(1f))
                            val place = HostScheduleClock.place(queueTimezone)
                            if (place != null) {
                                JobFactRow("Time zone", place, Modifier.weight(1f))
                            } else {
                                Spacer(Modifier.weight(1f))
                            }
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(Space.m)) {
                            val next = job.nextRunAtMs
                            if (next != null && job.enabled) {
                                JobFactRow("Next", HostScheduleClock.nextRun(next, queueTimezone), Modifier.weight(1f))
                            } else {
                                Spacer(Modifier.weight(1f))
                            }
                            val lastStarted = lastAutomationRun(runs, job)?.startedAtMs?.takeIf { it > 0 }
                                ?: job.lastRunAtMs?.takeIf { it > 0 }
                            JobFactRow("Last", JobCopy.lastRunWhen(lastStarted), Modifier.weight(1f))
                        }
                    }
                }
                TsCard {
                    Text(
                        job.prompt,
                        style = TsType.body,
                        color = LocalTsColors.current.textSecondary,
                        modifier = Modifier.padding(Space.m),
                    )
                }
                TsCard {
                    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                        Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                            if (live != null) {
                                TsSecondaryButton(
                                    label = "Stop",
                                    icon = ActionIcon.Stop.vector,
                                    enabled = !working,
                                    onClick = { onStop(live.id) },
                                )
                            } else if (hasPendingLaunch) {
                                TsSecondaryButton(
                                    label = "Check run",
                                    icon = ActionIcon.Refresh.vector,
                                    enabled = !working,
                                    onClick = { onCheckRun(job) },
                                )
                                if (canRetryLaunch) {
                                    TsAccentButton(
                                        label = "Retry run",
                                        icon = ActionIcon.Run.vector,
                                        enabled = !working,
                                        onClick = { onRetryRun(job) },
                                    )
                                }
                            } else {
                                TsAccentButton(
                                    label = if (working) "Starting" else "Run now",
                                    icon = ActionIcon.Run.vector,
                                    enabled = !working,
                                    onClick = onRun,
                                )
                            }
                            if (job.schedule.repeats) {
                                BrandToggleChip(if (job.enabled) "On" else "Off", job.enabled, { onToggle(job) })
                            }
                        }
                        if (live == null && hasPendingLaunch) {
                            Text(
                                "This run is not confirmed yet. Check it before starting another.",
                                style = TsType.caption,
                                color = LocalTsColors.current.textSecondary,
                            )
                        }
                    }
                }
                val ordered = remember(runs) { orderedAutomationRuns(runs) }
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

/// Every retained run for one job, live first, twenty at a time.
/// Port of `ClientAutomationHistoryView`.
@Composable
private fun AutomationHistoryPage(
    job: AutomationJob?,
    runs: List<AutomationRun>,
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
            subtitle = job?.name.orEmpty(),
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
                        "When this job runs, the output lands here.",
                    )
                    return@Column
                }
                val ordered = orderedAutomationRuns(runs)
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

/// One automation run on a phone: status and a live transcript.
/// Port of `ClientAutomationRunView`.
@Composable
private fun AutomationRunPage(
    model: AppViewModel,
    peer: String,
    run: AutomationRun?,
    liveRunID: String?,
    loaded: Boolean,
    loading: Boolean,
    working: Boolean,
    error: String?,
    hostLabel: String,
    queueTimezone: String?,
    onReload: () -> Unit,
    onBack: () -> Unit,
    onStop: () -> Unit,
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
                                HostScheduleClock.wallClock(run.startedAtMs, queueTimezone)
                                    ?: deviceDateTime(run.startedAtMs),
                                style = TsType.caption,
                                color = LocalTsColors.current.textSecondary,
                            )
                        }
                        JobFactRow("Backend", run.backend)
                    }
                }
                if (liveRunID != null && liveRunID != run.id) {
                    Text(
                        "A run is going. This is an earlier one.",
                        style = TsType.caption,
                        color = LocalTsColors.current.textSecondary,
                    )
                }
                if (run.isRunning) {
                    TsCard {
                        TsSecondaryButton(
                            label = "Stop",
                            icon = ActionIcon.Stop.vector,
                            enabled = !working,
                            onClick = onStop,
                            modifier = Modifier.padding(Space.m),
                        )
                    }
                }
                TsCard {
                    RunTranscript(
                        model = model,
                        peer = peer,
                        runID = run.id,
                        live = run.isRunning,
                        modifier = Modifier.padding(Space.m),
                    )
                }
            }
        }
    }
}

/// Host-wide scheduler defaults as a full page. Opened from the library,
/// never from a job editor, so it cannot look like a folder setting.
/// Port of `AutomationQueueView`.
@Composable
private fun SchedulerPage(
    queue: AutomationQueue,
    draft: QueueDraft?,
    runningCount: Int,
    loaded: Boolean,
    working: Boolean,
    error: String?,
    notice: String?,
    justSaved: Boolean,
    hostLabel: String,
    folderName: String,
    queueTimezone: String?,
    onDraft: (QueueDraft) -> Unit,
    onReload: () -> Unit,
    onBack: () -> Unit,
    onSave: (budget: Long, max: Long) -> Unit,
) {
    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(Space.s)) {
        JobScreenHeader(title = "Scheduler", subtitle = hostLabel, onBack = onBack)
        Column(
            Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            if (working) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    CircularProgressIndicator()
                    Text("Saving scheduler", color = LocalTsColors.current.textSecondary)
                }
            }
            if (error != null) {
                Text(error, style = TsType.callout, color = LocalTsColors.current.danger)
                if (draft == null) {
                    TsSecondaryButton(label = "Try again", icon = ActionIcon.Refresh.vector, small = true, enabled = !working, onClick = onReload)
                }
            }
            if (draft == null) {
                if (loaded && error == null) {
                    Text(
                        "The scheduler did not answer. Try again in a moment.",
                        style = TsType.caption,
                        color = LocalTsColors.current.textSecondary,
                    )
                    TsSecondaryButton(label = "Try again", icon = ActionIcon.Refresh.vector, small = true, enabled = !working, onClick = onReload)
                }
                return@Column
            }
            val dirty = !draft.matches(queue)
            if (notice != null && !dirty) {
                Text(notice, style = TsType.callout, color = LocalTsColors.current.textSecondary)
            }
            val budgetError = QueueValidation.budgetError(draft.noLimit, draft.budgetMinutes)
            val maxError = QueueValidation.maxConcurrentError(draft.maxConcurrent)
            if (budgetError != null && dirty && !draft.noLimit) {
                Text(budgetError, style = TsType.callout, color = LocalTsColors.current.danger)
            } else if (maxError != null && dirty) {
                Text(maxError, style = TsType.callout, color = LocalTsColors.current.danger)
            }
            Text(
                QueueCopy.editorScope(hostLabel, folderName),
                style = TsType.body,
                color = LocalTsColors.current.textPrimary,
            )
            Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                Text("Time limit", style = TsType.subheadline.copy(fontWeight = FontWeight.Medium), color = LocalTsColors.current.textPrimary)
                TimeLimitChips(
                    minutesText = draft.budgetMinutes,
                    noLimit = draft.noLimit,
                    onMinutesChange = { onDraft(draft.copy(budgetMinutes = it)) },
                    onNoLimitChange = { onDraft(draft.copy(noLimit = it)) },
                )
                if (!draft.noLimit && !QueueValidation.isBudgetPreset(draft.noLimit, draft.budgetMinutes)) {
                    OutlinedTextField(
                        draft.budgetMinutes,
                        { onDraft(draft.copy(budgetMinutes = it.filter(Char::isDigit))) },
                        modifier = Modifier.fillMaxWidth(),
                        label = { Text("Minutes") },
                    )
                }
                Text(
                    if (draft.noLimit) "New jobs are not stopped by a timer. A job can still set its own."
                    else "New jobs inherit this. A job can still set its own.",
                    style = TsType.caption,
                    color = LocalTsColors.current.textSecondary,
                )
            }
            Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    Text(
                        "Jobs at once",
                        style = TsType.subheadline.copy(fontWeight = FontWeight.Medium),
                        color = LocalTsColors.current.textPrimary,
                        modifier = Modifier.weight(1f),
                    )
                    SlotGauge(
                        filled = runningCount,
                        total = draft.maxConcurrent.trim().toIntOrNull() ?: 0,
                        uncapped = draft.maxConcurrent.trim() == "0",
                        tile = 12.dp,
                    )
                }
                ConcurrentChips(
                    countText = draft.maxConcurrent,
                    onCountChange = { onDraft(draft.copy(maxConcurrent = it)) },
                )
                if (!QueueValidation.isConcurrentPreset(draft.maxConcurrent)) {
                    OutlinedTextField(
                        draft.maxConcurrent,
                        { onDraft(draft.copy(maxConcurrent = it.filter(Char::isDigit))) },
                        modifier = Modifier.fillMaxWidth(),
                        label = { Text("Jobs at once") },
                    )
                }
                Text(
                    if (draft.maxConcurrent.trim() == "0") "No limit on how many jobs run together."
                    else "Extra jobs wait until a place is free.",
                    style = TsType.caption,
                    color = LocalTsColors.current.textSecondary,
                )
            }
            Text(
                QueueCopy.clockCaption(hostLabel, queueTimezone),
                style = TsType.caption,
                color = LocalTsColors.current.textSecondary,
            )
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                if (dirty) {
                    Text("Unsaved", style = TsType.caption.copy(fontWeight = FontWeight.Medium), color = LocalTsColors.current.warning)
                } else if (justSaved) {
                    Text("Saved", style = TsType.caption.copy(fontWeight = FontWeight.Medium), color = LocalTsColors.current.success)
                }
                Spacer(Modifier.weight(1f))
                TsAccentButton(
                    label = if (working) "Saving" else "Save scheduler",
                    icon = ActionIcon.Save.vector,
                    small = true,
                    enabled = !working && dirty && budgetError == null && maxError == null,
                    onClick = {
                        val budget = QueueValidation.budgetSeconds(draft.noLimit, draft.budgetMinutes) ?: return@TsAccentButton
                        val max = QueueValidation.maxConcurrent(draft.maxConcurrent) ?: return@TsAccentButton
                        onSave(budget, max)
                    },
                )
            }
        }
    }
}

/// Host-level queue editor state. Port of `AutomationQueueDraft`.
data class QueueDraft(val budgetMinutes: String, val noLimit: Boolean, val maxConcurrent: String) {
    companion object {
        fun fromQueue(queue: AutomationQueue): QueueDraft = QueueDraft(
            budgetMinutes = if (queue.defaultBudgetSeconds == 0L) "180" else maxOf(1, queue.defaultBudgetSeconds / 60).toString(),
            noLimit = queue.defaultBudgetSeconds == 0L,
            maxConcurrent = queue.maxConcurrent.toString(),
        )
    }

    fun matches(queue: AutomationQueue): Boolean {
        val budget = QueueValidation.budgetSeconds(noLimit, budgetMinutes) ?: return false
        val count = QueueValidation.maxConcurrent(maxConcurrent) ?: return false
        return budget == queue.defaultBudgetSeconds && count == queue.maxConcurrent
    }
}

/// Live tail of one run's readable transcript, capped like the Apple
/// inspector. Polls while the run is running, reads once when it is done.
@Composable
fun RunTranscript(model: AppViewModel, peer: String, runID: String, live: Boolean, modifier: Modifier = Modifier) {
    var text by remember(runID) { mutableStateOf("") }
    var error by remember(runID) { mutableStateOf<String?>(null) }
    ForegroundEffect(peer, runID, live) {
        var offset = 0L
        val builder = StringBuilder()
        var alive = true
        while (alive) {
            val chunk = runCatching {
                model.workspaceSection(peer, "automation.transcript", buildJsonObject {
                    put("id", runID)
                    put("offset", offset)
                }) as JsonObject
            }.getOrNull()
            if (chunk == null) {
                error = "Output is unavailable right now."
                break
            }
            builder.append(chunk.optStr("text") ?: "")
            if (builder.length > 256 * 1024) builder.delete(0, builder.length - 256 * 1024)
            offset = chunk.optLong("nextOffset") ?: break
            text = builder.toString()
            if (!live) break
            delay(1_000)
            val fresh = runCatching {
                model.workspaceSection(peer, "automation.runs", buildJsonObject {})
            }.getOrNull()
            val status = ((fresh as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList())
                .firstOrNull { it.optStr("id") == runID }?.optStr("status")
            if (status == null || status !in setOf("starting", "queued", "running", "stopping")) alive = false
        }
        text = builder.toString()
    }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(Space.xs)) {
        if (error != null) {
            Text(error!!, style = TsType.caption, color = LocalTsColors.current.danger)
        }
        Text(
            text.ifBlank { if (live) "Waiting for output…" else "No readable output." },
            style = TsType.mono(12),
            color = LocalTsColors.current.textPrimary,
        )
    }
}
