// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.automations

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
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
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.BrandToggleChip
import ai.tokenstat.tokenstat.ui.components.EmptyState
import ai.tokenstat.tokenstat.ui.components.SectionLabel
import ai.tokenstat.tokenstat.ui.components.TimeLimitChips
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.logic.HostContracts
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import ai.tokenstat.tokenstat.ui.marks.CadenceGlyph
import ai.tokenstat.tokenstat.ui.marks.EmptyArt
import ai.tokenstat.tokenstat.ui.marks.EmptyArtKind
import ai.tokenstat.tokenstat.ui.tasks.BackendRef
import ai.tokenstat.tokenstat.ui.tasks.FolderRef
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

/// The automations workbench: jobs with their schedules on the host clock,
/// run/stop, complete paginated run history live-first, the Writing/Settings
/// editor, and host-level queue settings.
///
/// Ports `ClientAutomationWorkspace` plus the `AutomationsModel` operation
/// rules: create-once and run-once receipts where the host offers them
/// (protocol 21+), revision-checked `automation.edit` saves with the
/// conflict flow, and plain `create`/`run`/`update` below that.
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
    var creating by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<AutomationJob?>(null) }
    var historyJob by remember { mutableStateOf<String?>(null) }
    var pendingCreates by remember { mutableStateOf<Map<String, AutomationJob>>(emptyMap()) }
    var pendingLaunches by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
    var queueDraft by remember { mutableStateOf<QueueDraft?>(null) }

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

    fun lastRun(job: AutomationJob): AutomationRun? {
        val byID = job.lastRunID?.let { id -> runs.firstOrNull { it.id == id } }
        if (byID != null) return byID
        return runs.firstOrNull { it.jobId == job.id }
    }

    suspend fun toggle(job: AutomationJob) {
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
        notice = "Started ${job.name}."
        error = null
        load()
        return true
    }

    suspend fun run(job: AutomationJob) {
        val operationID = pendingLaunches[job.id] ?: TaskOperations.automationRunID()
        pendingLaunches = pendingLaunches + (job.id to operationID)
        working = true
        try {
            if (supportsReceipts) {
                val element = model.workspaceSection(peer, "automation.runOnce", buildJsonObject {
                    put("id", job.id)
                    put("operationId", operationID)
                })
                confirmRun(AutomationRunOutcome.parse(element as JsonObject), job)
            } else {
                model.workspaceSection(peer, "automation.run", buildJsonObject { put("id", job.id) })
                pendingLaunches = pendingLaunches - job.id
                notice = "Started ${job.name}."
                error = null
                load()
            }
        } catch (e: Exception) {
            if (supportsReceipts) {
                val receipt = runCatching {
                    model.workspaceSection(peer, "automation.runReceipt", buildJsonObject { put("operationId", operationID) })
                }.getOrNull()
                if (receipt != null && receipt !is JsonNull) {
                    confirmRun(AutomationRunOutcome.parse(receipt as JsonObject), job)
                    return
                }
            }
            error = TunnelCopy.display(e.message ?: "The request failed.", hostLabel)
        } finally {
            working = false
        }
    }

    suspend fun checkLaunch(job: AutomationJob) {
        val operationID = pendingLaunches[job.id] ?: return
        working = true
        try {
            val element = model.workspaceSection(peer, "automation.runReceipt", buildJsonObject {
                put("operationId", operationID)
            })
            if (element is JsonNull) {
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

    suspend fun stop(run: AutomationRun) {
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

    LaunchedEffect(peer) { load() }
    val anyLive = runs.any { it.isRunning }
    LaunchedEffect(anyLive, peer) {
        if (!anyLive) return@LaunchedEffect
        while (true) {
            delay(3_000)
            if (!working && !loading) load()
        }
    }

    val scoped = remember(jobs, workspaceID) { jobs.filter { it.workspaceID == workspaceID } }
    val timezone = HostScheduleClock.resolved(queue.timezone).orEmpty()

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(Modifier.fillMaxSize().padding(Space.m)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Automations", style = TsType.cardTitle, color = LocalTsColors.current.textPrimary)
                    Text(folderName.ifBlank { hostLabel }, style = TsType.caption, color = LocalTsColors.current.textSecondary)
                }
                IconButton(onClick = { creating = true }) {
                    Icon(ActionIcon.Create.vector, "New automation", tint = LocalTsColors.current.accent)
                }
                IconButton(onClick = onDismiss) {
                    Icon(ActionIcon.Dismiss.vector, "Close", tint = LocalTsColors.current.controlGlyph)
                }
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
                    Text("Loading automations", color = LocalTsColors.current.textSecondary)
                }
            }
            PullToRefreshBox(isRefreshing = loading && loaded, onRefresh = { scope.launch { load() } }, modifier = Modifier.weight(1f)) {
                LazyColumn(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(Space.s)) {
                    if (loaded && scoped.isEmpty()) {
                        item {
                            EmptyState(
                                ActionIcon.Scheduled.vector,
                                "No automations yet",
                                "A job runs its prompt on the computer, on its schedule, whether this device is awake or not.",
                                art = { EmptyArt(EmptyArtKind.Automations) },
                            )
                        }
                    }
                    items(scoped, key = { it.id }) { job ->
                        val last = lastRun(job)
                        TsCard {
                            Column(Modifier.padding(Space.m), verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    CadenceGlyph(
                                        kind = job.schedule.kind.name.lowercase(),
                                        weekdays = job.schedule.weekdays,
                                        weekday = job.schedule.weekday,
                                        enabled = job.enabled,
                                    )
                                    Spacer(Modifier.padding(start = Space.s))
                                    Column(Modifier.weight(1f)) {
                                        Text(job.name, style = TsType.body.copy(fontWeight = FontWeight.SemiBold), color = LocalTsColors.current.textPrimary)
                                        Text(
                                            HostScheduleClock.listSubtitle(job.schedule.summary, job.nextRunAtMs, job.enabled, job.schedule.repeats, queue.timezone),
                                            style = TsType.caption,
                                            color = LocalTsColors.current.textSecondary,
                                        )
                                    }
                                    BrandToggleChip(if (job.enabled) "On" else "Off", job.enabled, { scope.launch { toggle(job) } })
                                }
                                if (last != null) {
                                    Text(
                                        "Last run · ${last.endedLabel}",
                                        style = TsType.caption,
                                        color = if (last.status == "error") LocalTsColors.current.danger else LocalTsColors.current.textSecondary,
                                    )
                                }
                                Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                                    TsAccentButton(label = "Run", icon = ActionIcon.Run.vector, small = true, enabled = !working, onClick = { scope.launch { run(job) } })
                                    TsSecondaryButton(label = "Edit", small = true, onClick = { editing = job })
                                    TsSecondaryButton(
                                        label = if (historyJob == job.id) "Hide runs" else "Runs",
                                        icon = ActionIcon.History.vector,
                                        small = true,
                                        onClick = { historyJob = if (historyJob == job.id) null else job.id },
                                    )
                                    if (pendingLaunches.containsKey(job.id)) {
                                        TsSecondaryButton(label = "Check run", small = true, enabled = !working, onClick = { scope.launch { checkLaunch(job) } })
                                    }
                                }
                                if (pendingLaunches.containsKey(job.id)) {
                                    Text(
                                        "Run sent and not confirmed yet. Check the receipt before running again.",
                                        style = TsType.caption,
                                        color = LocalTsColors.current.textSecondary,
                                    )
                                }
                                if (historyJob == job.id) {
                                    val jobRuns = runs.filter { it.jobId == job.id }
                                    RunHistorySection(
                                        runs = jobRuns,
                                        working = working,
                                        onStop = { scope.launch { stop(it) } },
                                        model = model,
                                        peer = peer,
                                        hostLabel = hostLabel,
                                    )
                                }
                            }
                        }
                    }
                    val draft = queueDraft
                    if (draft != null) {
                        item {
                            QueueSettingsCard(
                                draft = draft,
                                saved = QueueDraft.fromQueue(queue),
                                timezoneCaption = HostScheduleClock.timesCaption(hostLabel, queue.timezone),
                                onDraft = { queueDraft = it },
                                onSave = { budget, max ->
                                    scope.launch {
                                        working = true
                                        runCatching {
                                            model.workspaceSection(peer, "automation.setQueue", buildJsonObject {
                                                put("defaultBudgetSeconds", budget)
                                                put("maxConcurrent", max)
                                            }) as JsonObject
                                        }.onSuccess { element ->
                                            queue = AutomationQueue.parse(element)
                                            queueDraft = QueueDraft.fromQueue(queue)
                                            notice = "Scheduler saved."
                                            error = null
                                        }.onFailure {
                                            error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel)
                                        }
                                        working = false
                                    }
                                },
                            )
                        }
                    }
                }
            }
        }
    }
    if (creating) {
        AutomationEditorDialog(
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
            onDismiss = { creating = false },
        )
    }
    val editingJob = editing
    if (editingJob != null) {
        AutomationEditorDialog(
            model = model,
            peer = peer,
            hostLabel = hostLabel,
            protocol = protocol,
            workspaceID = workspaceID,
            folderName = folderName,
            existing = editingJob,
            backends = backends,
            defaultBudget = queue.defaultBudgetSeconds,
            timezone = timezone,
            onSaved = { scope.launch { load() } },
            onDismiss = { editing = null },
        )
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

}

@Composable
private fun QueueSettingsCard(
    draft: QueueDraft,
    saved: QueueDraft,
    timezoneCaption: String,
    onDraft: (QueueDraft) -> Unit,
    onSave: (budget: Long, max: Long) -> Unit,
) {
    val budgetError = QueueValidation.budgetError(draft.noLimit, draft.budgetMinutes)
    val maxError = QueueValidation.maxConcurrentError(draft.maxConcurrent)
    TsCard(title = "Scheduler") {
        Column(Modifier.padding(Space.m), verticalArrangement = Arrangement.spacedBy(Space.s)) {
            Text(timezoneCaption, style = TsType.caption, color = LocalTsColors.current.textSecondary)
            TimeLimitChips(
                minutesText = if (draft.noLimit) "" else draft.budgetMinutes,
                noLimit = draft.noLimit,
                onMinutesChange = { onDraft(draft.copy(budgetMinutes = it)) },
                onNoLimitChange = { onDraft(draft.copy(noLimit = it)) },
            )
            OutlinedTextField(
                draft.budgetMinutes,
                { onDraft(draft.copy(budgetMinutes = it)) },
                modifier = Modifier.fillMaxWidth(),
                enabled = !draft.noLimit,
                label = { Text("Default time limit (minutes)") },
            )
            if (budgetError != null && !draft.noLimit) {
                Text(budgetError, style = TsType.caption, color = LocalTsColors.current.danger)
            }
            OutlinedTextField(
                draft.maxConcurrent,
                { onDraft(draft.copy(maxConcurrent = it.filter(Char::isDigit))) },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Max concurrent jobs") },
            )
            if (maxError != null) {
                Text(maxError, style = TsType.caption, color = LocalTsColors.current.danger)
            }
            TsAccentButton(
                label = "Save scheduler",
                small = true,
                enabled = draft != saved && budgetError == null && maxError == null,
                onClick = {
                    val budget = QueueValidation.budgetSeconds(draft.noLimit, draft.budgetMinutes) ?: return@TsAccentButton
                    val max = QueueValidation.maxConcurrent(draft.maxConcurrent) ?: return@TsAccentButton
                    onSave(budget, max)
                },
            )
        }
    }
}

/// Complete run history, live-first, in pages of 20. Port of
/// `AutomationRunHistory` plus the history destination: live runs stay on
/// the first page so Stop is never behind Earlier runs.
@Composable
fun RunHistorySection(
    runs: List<AutomationRun>,
    working: Boolean,
    onStop: (AutomationRun) -> Unit,
    model: AppViewModel,
    peer: String,
    hostLabel: String,
) {
    var shown by remember { mutableStateOf(20) }
    var openTranscript by remember { mutableStateOf<String?>(null) }
    val ordered = remember(runs) {
        RunHistory.ordered(runs.map { RunRef(it.id, it.startedAtMs, it.isRunning) })
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
                            ai.tokenstat.tokenstat.ui.logic.RelativeClock.label(run.startedAtMs),
                            style = TsType.caption,
                            color = LocalTsColors.current.textSecondary,
                        )
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                        if (run.isRunning) {
                            TsSecondaryButton(label = "Stop", icon = ActionIcon.Stop.vector, small = true, enabled = !working, onClick = { onStop(run) })
                        }
                        TsSecondaryButton(
                            label = if (openTranscript == run.id) "Hide output" else "Output",
                            small = true,
                            onClick = { openTranscript = if (openTranscript == run.id) null else run.id },
                        )
                    }
                    if (openTranscript == run.id) {
                        RunTranscript(model = model, peer = peer, hostLabel = hostLabel, runID = run.id, live = run.isRunning)
                    }
                }
            }
        }
        if (remaining > 0) {
            TsSecondaryButton(label = "Earlier runs ($remaining)", small = true, onClick = { shown += 20 })
        }
    }
}

/// Live tail of one run's readable transcript, capped like the Apple
/// inspector. Polls while the run is running, reads once when it is done.
@Composable
fun RunTranscript(model: AppViewModel, peer: String, hostLabel: String, runID: String, live: Boolean) {
    var text by remember(runID) { mutableStateOf("") }
    var error by remember(runID) { mutableStateOf<String?>(null) }
    LaunchedEffect(runID) {
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
    if (error != null) {
        Text(error!!, style = TsType.caption, color = LocalTsColors.current.danger)
    }
    Text(
        text.ifBlank { if (live) "Waiting for output…" else "No readable output." },
        style = TsType.mono(12),
        color = LocalTsColors.current.textPrimary,
    )
}
