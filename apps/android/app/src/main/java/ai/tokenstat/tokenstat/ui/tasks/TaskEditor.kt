// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.tasks

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.BrandToggleChip
import ai.tokenstat.tokenstat.ui.components.ChoiceChip
import ai.tokenstat.tokenstat.ui.components.TimeLimitChips
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.logic.HostContracts
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/// Creation and editing use the same writing space and settings vocabulary.
/// Port of `TaskFieldsView`: title plus prompt (or command for the `sh`
/// backend), folder, priority, agent with model and effort, time limit with
/// the shared chips, and the validation line.
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun TaskFields(
    fields: TaskEditorDraft,
    onFields: (TaskEditorDraft) -> Unit,
    backends: List<BackendRef>,
    folders: List<FolderRef>,
    enabled: Boolean,
    showValidation: Boolean = true,
) {
    Column(verticalArrangement = Arrangement.spacedBy(Space.m)) {
        OutlinedTextField(
            fields.title,
            { onFields(fields.copy(title = it)) },
            modifier = Modifier.fillMaxWidth(),
            enabled = enabled,
            label = { Text("Task title") },
            textStyle = TsType.cardTitle,
        )
        OutlinedTextField(
            fields.prompt,
            { onFields(fields.copy(prompt = it)) },
            modifier = Modifier.fillMaxWidth(),
            enabled = enabled,
            label = { Text(if (fields.backend == "sh") "Command" else "Prompt") },
            minLines = 6,
        )
        Text("Task settings", style = TsType.body.copy(fontWeight = FontWeight.SemiBold), color = LocalTsColors.current.textPrimary)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
            ChoiceChip("Uncategorized", fields.workspaceID.isEmpty(), { onFields(fields.copy(workspaceID = "")) })
            folders.forEach { folder ->
                ChoiceChip(folder.name.ifBlank { folder.id }, fields.workspaceID == folder.id, { onFields(fields.copy(workspaceID = folder.id)) })
            }
            if (fields.workspaceID.isNotEmpty() && folders.none { it.id == fields.workspaceID }) {
                ChoiceChip("Unavailable folder", true, {})
            }
        }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
            listOf("low" to "Low", "normal" to "Normal", "high" to "High").forEach { (value, label) ->
                ChoiceChip(label, fields.priority == value, { onFields(fields.copy(priority = value)) })
            }
        }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
            ChoiceChip("Choose later", fields.backend.isEmpty(), { onFields(fields.copy(backend = "", model = "", effort = "")) })
            backends.forEach { backend ->
                ChoiceChip(backend.label.ifBlank { backend.id }, fields.backend == backend.id, {
                    if (backend.id != fields.backend) onFields(fields.copy(backend = backend.id, model = "", effort = ""))
                })
            }
            if (fields.backend.isNotEmpty() && backends.none { it.id == fields.backend }) {
                ChoiceChip("${fields.backend} · Unavailable", true, {})
            }
        }
        val backend = backends.firstOrNull { it.id == fields.backend }
        if (backend != null && (backend.models.isNotEmpty() || fields.model.isNotEmpty())) {
            val options = (backend.models + listOf(fields.model).filter { it.isNotEmpty() }).distinct()
            FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                ChoiceChip("Default", fields.model.isEmpty(), { onFields(fields.copy(model = "")) })
                options.forEach { model ->
                    ChoiceChip(
                        model,
                        fields.model == model,
                        { onFields(fields.copy(model = model)) },
                    )
                }
            }
            if (fields.model.isNotEmpty() && !backend.models.contains(fields.model)) {
                Text(
                    "This computer does not list the saved model. Keep it or choose another.",
                    style = TsType.caption,
                    color = LocalTsColors.current.textSecondary,
                )
            }
        }
        if (backend != null && (backend.efforts.isNotEmpty() || fields.effort.isNotEmpty())) {
            val options = (listOf("") + backend.efforts + listOf(fields.effort).filter { it.isNotEmpty() }).distinct()
            FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                options.forEach { effort ->
                    ChoiceChip(if (effort.isEmpty()) "Default" else effort, fields.effort == effort, { onFields(fields.copy(effort = effort)) })
                }
            }
        }
        BrandToggleChip("No time limit", fields.noTimeLimit, { onFields(fields.copy(noTimeLimit = !fields.noTimeLimit)) })
        if (!fields.noTimeLimit) {
            TimeLimitChips(
                minutesText = if (fields.budgetUnit == "minutes") fields.budgetValue else "",
                noLimit = false,
                onMinutesChange = { onFields(fields.copy(budgetValue = it, budgetUnit = "minutes")) },
                onNoLimitChange = {},
            )
            OutlinedTextField(
                fields.budgetValue,
                { onFields(fields.copy(budgetValue = it)) },
                modifier = Modifier.fillMaxWidth(),
                enabled = enabled,
                label = { Text("Time limit") },
            )
            FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                ChoiceChip("Minutes", fields.budgetUnit == "minutes", { onFields(fields.copy(budgetUnit = "minutes")) })
                ChoiceChip("Seconds", fields.budgetUnit == "seconds", { onFields(fields.copy(budgetUnit = "seconds")) })
            }
        }
        if (showValidation && fields.validation != null) {
            Text(fields.validation!!, style = TsType.caption, color = LocalTsColors.current.danger)
        }
    }
}

/// The full detail editor: title, prompt/command, folder, priority, backend,
/// model, effort, budget, no-time-limit, all column-safe saves, foreground
/// and background run with receipts, Stop, and View run/result.
///
/// Operation rules, ported from `TaskEditorSession`: the edit is sent with
/// the baseline revision and one checked edit can win; a retry of a run
/// repeats the same durable operation id and can never create a second run;
/// receipt reads never launch work.
@Composable
fun TaskEditorDialog(
    model: AppViewModel,
    peer: String,
    hostLabel: String,
    protocol: Long?,
    cardId: String,
    backends: List<BackendRef>,
    folders: List<FolderRef>,
    onViewRun: (runID: String, workspaceID: String) -> Unit,
    onOpenTerminal: (String) -> Unit,
    onSaved: () -> Unit,
    onDismiss: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val supportsExecution = HostContracts.supportsTaskExecution(protocol)
    var baseline by remember { mutableStateOf<TaskCard?>(null) }
    var current by remember { mutableStateOf<TaskCard?>(null) }
    var fields by remember { mutableStateOf<TaskEditorDraft?>(null) }
    var loaded by remember { mutableStateOf(false) }
    var working by remember { mutableStateOf(false) }
    var conflict by remember { mutableStateOf(false) }
    var missing by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var pendingEdit by remember { mutableStateOf(false) }
    var pendingRun by remember { mutableStateOf<PendingTaskRun?>(null) }
    var lastRun by remember { mutableStateOf<TaskRunOutcome?>(null) }
    var liveBackends by remember { mutableStateOf(backends) }
    var liveFolders by remember { mutableStateOf(folders) }

    suspend fun readCurrent(): TaskCard? {
        val element = model.workspaceSection(peer, "todo.get", buildJsonObject { put("id", cardId) })
        if (element is JsonNull) return null
        return TaskCard.parse(element as JsonObject)
    }

    suspend fun load() {
        working = true
        try {
            val card = readCurrent()
            if (card == null) {
                missing = true
                error = "This task was deleted on the computer. Your draft is still here."
            } else if (card.revision == null) {
                error = "This computer did not return the task's revision. Reload it before saving."
            } else {
                baseline = card
                current = card
                fields = TaskEditorDraft.fromCard(card)
                error = null
            }
            runCatching { model.workspaceSection(peer, "automation.backends", buildJsonObject {}) }
                .onSuccess { element ->
                    liveBackends = ((element as? kotlinx.serialization.json.JsonArray)
                        ?.filterIsInstance<JsonObject>() ?: emptyList()).map(BackendRef::parse)
                }
            runCatching { model.workspaceSection(peer, "workspace.list", buildJsonObject {}) }
                .onSuccess { element ->
                    liveFolders = ((element as? kotlinx.serialization.json.JsonArray)
                        ?.filterIsInstance<JsonObject>() ?: emptyList()).map(FolderRef::parse)
                }
            loaded = true
        } catch (e: Exception) {
            error = TunnelCopy.display(e.message ?: "The request failed.", hostLabel)
        } finally {
            working = false
        }
    }

    suspend fun refresh() {
        if (!loaded || working) return
        working = true
        try {
            val fresh = readCurrent()
            current = fresh
            if (fresh == null) {
                missing = true
                error = "This task was deleted on the computer. Your draft is still here."
            } else if (fresh.revision == null) {
                error = "This computer did not return the task's revision. Reload it before saving."
            } else {
                val base = baseline
                val draft = fields
                error = null
                if (base != null && draft != null) {
                    if (pendingEdit && fresh.revision != null) {
                        if (draft.matches(fresh)) {
                            baseline = fresh
                            pendingEdit = false
                            conflict = false
                            fields = TaskEditorDraft.fromCard(fresh)
                        } else {
                            // A timed-out edit may still arrive. Retrying the
                            // same base revision is safe: only one checked
                            // edit can win.
                            pendingEdit = false
                            conflict = fresh.revision != base.revision
                            if (!conflict) error = "The task has not changed. Your draft is ready to save again."
                        }
                    } else if (fresh.revision != base.revision) {
                        if (draft != null && !draft.matches(base)) {
                            conflict = true
                        } else {
                            baseline = fresh
                            fields = TaskEditorDraft.fromCard(fresh)
                            conflict = false
                        }
                    }
                }
            }
        } catch (e: Exception) {
            error = TunnelCopy.display(e.message ?: "The request failed.", hostLabel)
        } finally {
            working = false
        }
    }

    suspend fun save() {
        val base = baseline
        val draft = fields
        if (base?.revision == null || draft == null || draft.validation != null) return
        working = true
        pendingEdit = true
        try {
            val element = model.workspaceSection(peer, "todo.edit", buildJsonObject {
                put("id", base.id)
                put("expectedRevision", base.revision!!)
                put("title", draft.title.trim())
                put("notes", draft.prompt)
                put("workspaceId", draft.workspaceID)
                put("priority", draft.priority)
                put("backend", draft.backend)
                put("model", draft.model)
                put("effort", draft.effort)
                put("budgetSeconds", draft.budgetSeconds!!)
            })
            baseline = TaskCard.parse(element as JsonObject)
            current = baseline
            pendingEdit = false
            conflict = false
            error = null
            onSaved()
        } catch (e: Exception) {
            error = "Check the saved task before trying again. Your draft is still here. ${TunnelCopy.display(e.message ?: "", hostLabel)}"
        } finally {
            working = false
        }
    }

    suspend fun acceptOutcome(outcome: TaskRunOutcome, submission: PendingTaskRun): TaskRunOutcome? {
        return when (val accepted = acceptTaskRun(outcome, submission.operationID, submission.cardID)) {
            is RunAcceptance.Accepted -> {
                outcome.card?.let {
                    baseline = it
                    current = it
                    fields = TaskEditorDraft.fromCard(it)
                }
                pendingRun = null
                lastRun = outcome
                error = null
                onSaved()
                outcome
            }
            is RunAcceptance.Pending -> {
                lastRun = outcome
                error = accepted.message
                outcome
            }
            is RunAcceptance.Rejected -> {
                if (!outcome.hasRun && outcome.card == null) {
                    pendingRun = null
                    missing = true
                }
                error = accepted.message
                null
            }
        }
    }

    suspend fun submitRun(submission: PendingTaskRun): TaskRunOutcome? {
        working = true
        try {
            val element = model.workspaceSection(peer, "todo.runTask", buildJsonObject {
                put("id", submission.cardID)
                put("expectedRevision", submission.revision)
                put("operationId", submission.operationID)
                put("placement", submission.placement.raw)
            })
            val outcome = TaskRunOutcome.parse(element as JsonObject)
            return acceptOutcome(outcome, submission)
        } catch (e: Exception) {
            error = "The run result is not confirmed. Check this request before starting another run. ${TunnelCopy.display(e.message ?: "", hostLabel)}"
            return null
        } finally {
            working = false
        }
    }

    suspend fun reconcileRun() {
        val submission = pendingRun ?: return
        if (working) return
        working = true
        try {
            val element = model.workspaceSection(peer, "todo.runReceipt", buildJsonObject {
                put("operationId", submission.operationID)
            })
            if (element is JsonNull) {
                error = "The computer has not accepted this run request. Retry the same request when the connection is ready."
            } else {
                acceptOutcome(TaskRunOutcome.parse(element as JsonObject), submission)
            }
        } catch (e: Exception) {
            error = "The run result is still unavailable. Your request is kept on this device. ${TunnelCopy.display(e.message ?: "", hostLabel)}"
        } finally {
            working = false
        }
    }

    suspend fun stop() {
        val base = baseline
        val delegate = base?.delegate
        if (base?.revision == null || delegate == null || pendingRun != null) return
        if (delegate.status !in setOf("starting", "queued", "running")) return
        working = true
        try {
            val element = model.workspaceSection(peer, "todo.stopTask", buildJsonObject {
                put("id", base.id)
                put("expectedRevision", base.revision!!)
                put("runId", delegate.runId)
            })
            baseline = TaskCard.parse(element as JsonObject)
            current = baseline
            error = null
            onSaved()
        } catch (e: Exception) {
            error = "The stop was not confirmed. Reload this task before trying again. ${TunnelCopy.display(e.message ?: "", hostLabel)}"
        } finally {
            working = false
        }
    }

    suspend fun openOutcome(outcome: TaskRunOutcome?) {
        if (outcome == null) return
        onSaved()
        if (outcome.placement == TaskRunPlacement.FOREGROUND) {
            val pty = outcome.ptyID
            if (!pty.isNullOrEmpty()) {
                onOpenTerminal(pty)
                return
            }
        }
        onViewRun(outcome.runID, outcome.runWorkspaceID ?: baseline?.workspaceID ?: "")
    }

    LaunchedEffect(cardId) { load() }

    val base = baseline
    val draft = fields
    val dirty = base != null && draft != null && !draft.matches(base)
    val readiness = base?.let { taskRunReadiness(it, liveFolders) }
    val canSave = loaded && !working && !conflict && !missing && base?.revision != null && pendingEdit.not() && pendingRun == null && draft?.validation == null && dirty
    val canRun = supportsExecution && loaded && !working && !dirty && !conflict && !missing &&
        base?.revision != null && !pendingEdit && pendingRun == null &&
        base?.delegate?.isRunning != true && readiness == null
    val delegate = base?.delegate

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(Modifier.fillMaxSize().padding(Space.m).verticalScroll(rememberScrollState())) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Task", style = TsType.cardTitle, color = LocalTsColors.current.textPrimary)
                    Text(hostLabel, style = TsType.caption, color = LocalTsColors.current.textSecondary)
                }
                IconButton(onClick = onDismiss) {
                    Icon(ActionIcon.Dismiss.vector, "Close", tint = LocalTsColors.current.controlGlyph)
                }
            }
            if (error != null) {
                Banner(error!!, BannerSeverity.DANGER)
                if (!pendingEdit) {
                    TsSecondaryButton(label = "Reload task", small = true, onClick = { scope.launch { load() } })
                }
            }
            if (working) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    CircularProgressIndicator()
                    Text("Updating task", color = LocalTsColors.current.textSecondary)
                }
            }
            if (loaded && !supportsExecution) {
                Text(
                    "Update $hostLabel's tokenstat to run and stop tasks from here.",
                    style = TsType.caption,
                    color = LocalTsColors.current.textSecondary,
                )
            }
            if (supportsExecution && !dirty && delegate?.isRunning != true && readiness != null) {
                Text(readiness, style = TsType.caption, color = LocalTsColors.current.textSecondary)
            }
            if (delegate != null) {
                TsCard {
                    Column(Modifier.padding(Space.m), verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                        Text(
                            if (delegate.isRunning) delegate.label else "Last run · ${delegate.label}",
                            style = TsType.body.copy(fontWeight = FontWeight.SemiBold),
                            color = LocalTsColors.current.textPrimary,
                        )
                        val runError = delegate.error
                        if (!runError.isNullOrEmpty()) {
                            Text(runError, style = TsType.caption, color = LocalTsColors.current.danger, maxLines = 3)
                        } else {
                            Text(
                                if (delegate.isRunning) "This run continues on the connected computer." else "The result remains linked to this task.",
                                style = TsType.caption,
                                color = LocalTsColors.current.textSecondary,
                            )
                        }
                    }
                }
            }
            if (draft != null) {
                TaskFields(
                    fields = draft,
                    onFields = { fields = it },
                    backends = liveBackends,
                    folders = liveFolders,
                    enabled = loaded && !working && pendingRun == null,
                )
            }
            val snapshot = current
            if (conflict && snapshot != null) {
                TsCard {
                    Column(Modifier.padding(Space.m), verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                        Text("Changed on the computer", style = TsType.body.copy(fontWeight = FontWeight.SemiBold), color = LocalTsColors.current.textPrimary)
                        Text(snapshot.title, color = LocalTsColors.current.textPrimary)
                        Text(snapshot.notes, color = LocalTsColors.current.textPrimary)
                        Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                            TsSecondaryButton(label = "Use computer version", small = true, onClick = {
                                baseline = snapshot
                                fields = TaskEditorDraft.fromCard(snapshot)
                                conflict = false
                                error = null
                            })
                            TsSecondaryButton(label = "Keep my draft", small = true, onClick = {
                                baseline = snapshot
                                conflict = false
                                error = null
                            })
                        }
                    }
                }
            }
            Spacer(Modifier.padding(top = Space.s))
            val pending = pendingRun
            when {
                pendingEdit -> {
                    TsAccentButton(label = "Check saved task", enabled = !working, onClick = {
                        scope.launch { refresh(); onSaved() }
                    })
                }
                pending != null -> {
                    Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                        TsSecondaryButton(label = "Check run", enabled = !working, onClick = {
                            scope.launch {
                                reconcileRun()
                                openOutcome(lastRun)
                            }
                        })
                        TsAccentButton(label = "Retry same request", enabled = !working, onClick = {
                            scope.launch { openOutcome(submitRun(pending)) }
                        })
                    }
                }
                else -> {
                    if (delegate?.isRunning == true) {
                        Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                            TsSecondaryButton(
                                label = if (delegate.status == "stopping") "Stopping…" else "Stop",
                                icon = ActionIcon.Stop.vector,
                                enabled = supportsExecution && !working,
                                onClick = { scope.launch { stop(); onSaved() } },
                            )
                            TsAccentButton(label = "View run", icon = ActionIcon.Preview.vector, onClick = {
                                scope.launch {
                                    val terminal = lastRun?.takeIf { it.runID == delegate.runId }
                                    val pty = terminal?.ptyID
                                    if (terminal?.placement == TaskRunPlacement.FOREGROUND && !pty.isNullOrEmpty()) {
                                        onOpenTerminal(pty)
                                    } else {
                                        onViewRun(delegate.runId, base?.workspaceID ?: "")
                                    }
                                }
                            })
                        }
                    } else if (supportsExecution) {
                        if (delegate != null) {
                            TsSecondaryButton(label = "View last result", icon = ActionIcon.Preview.vector, onClick = {
                                onViewRun(delegate.runId, base?.workspaceID ?: "")
                            })
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                            TsSecondaryButton(
                                label = "Run in background",
                                icon = ActionIcon.Run.vector,
                                enabled = canRun,
                                onClick = {
                                    val revision = base?.revision ?: return@TsSecondaryButton
                                    val submission = PendingTaskRun(TaskOperations.runID(), base.id, revision, TaskRunPlacement.BACKGROUND)
                                    pendingRun = submission
                                    scope.launch { openOutcome(submitRun(submission)) }
                                },
                            )
                            TsSecondaryButton(
                                label = "Run in terminal",
                                icon = ActionIcon.Run.vector,
                                enabled = canRun,
                                onClick = {
                                    val revision = base?.revision ?: return@TsSecondaryButton
                                    val submission = PendingTaskRun(TaskOperations.runID(), base.id, revision, TaskRunPlacement.FOREGROUND)
                                    pendingRun = submission
                                    scope.launch { openOutcome(submitRun(submission)) }
                                },
                            )
                        }
                    }
                    TsAccentButton(
                        label = "Save task",
                        icon = ActionIcon.Save.vector,
                        enabled = canSave,
                        onClick = { scope.launch { save() } },
                    )
                }
            }
        }
    }
}

private data class PendingTaskRun(
    val operationID: String,
    val cardID: String,
    val revision: Long,
    val placement: TaskRunPlacement,
)

/// Task creation through `todo.createOnce`: the submission is saved before
/// it leaves the device, receipt reads never create work, and an explicit
/// retry always repeats the original operation. Port of
/// `TaskCreationSession`.
@Composable
fun TaskCreateDialog(
    model: AppViewModel,
    peer: String,
    hostLabel: String,
    protocol: Long?,
    initialFolder: String,
    defaultBudget: Long,
    backends: List<BackendRef>,
    folders: List<FolderRef>,
    onCreated: () -> Unit,
    onDismiss: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val supported = HostContracts.supportsTaskCreation(protocol)
    var fields by remember { mutableStateOf(TaskEditorDraft.blank(initialFolder, defaultBudget)) }
    var working by remember { mutableStateOf(false) }
    var canRetry by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var notice by remember { mutableStateOf<String?>(null) }
    var pending by remember { mutableStateOf<String?>(null) }
    var outcome by remember { mutableStateOf<TaskCreationOutcome?>(null) }
    var liveBackends by remember { mutableStateOf(backends) }
    var liveFolders by remember { mutableStateOf(folders) }

    LaunchedEffect(peer) {
        runCatching { model.workspaceSection(peer, "automation.backends", buildJsonObject {}) }
            .onSuccess { element ->
                liveBackends = ((element as? kotlinx.serialization.json.JsonArray)
                    ?.filterIsInstance<JsonObject>() ?: emptyList()).map(BackendRef::parse)
            }
        runCatching { model.workspaceSection(peer, "workspace.list", buildJsonObject {}) }
            .onSuccess { element ->
                liveFolders = ((element as? kotlinx.serialization.json.JsonArray)
                    ?.filterIsInstance<JsonObject>() ?: emptyList()).map(FolderRef::parse)
            }
    }

    fun confirm(result: TaskCreationOutcome, operationID: String) {
        if (result.operationID != operationID) {
            error = "The computer returned a different creation. Check this task again."
            return
        }
        outcome = result
        canRetry = false
        error = null
        notice = null
        onCreated()
    }

    suspend fun submit(operationID: String) {
        canRetry = false
        error = null
        notice = null
        working = true
        try {
            val budget = fields.budgetSeconds
            if (budget == null) {
                error = fields.validation
                return
            }
            val element = model.workspaceSection(peer, "todo.createOnce", buildJsonObject {
                put("title", fields.title.trim())
                put("kind", "task")
                put("notes", fields.prompt)
                put("column", "backlog")
                put("backend", fields.backend)
                put("workspaceId", fields.workspaceID)
                put("priority", fields.priority)
                put("model", fields.model)
                put("effort", fields.effort)
                put("budgetSeconds", budget)
                put("operationId", operationID)
            })
            confirm(TaskCreationOutcome.parse(element as JsonObject), operationID)
        } catch (e: Exception) {
            val receipt = runCatching {
                model.workspaceSection(peer, "todo.creationReceipt", buildJsonObject { put("operationId", operationID) })
            }.getOrNull()
            if (receipt != null && receipt !is JsonNull) {
                runCatching { confirm(TaskCreationOutcome.parse(receipt as JsonObject), operationID) }
                    .onFailure { error = "The creation has not been confirmed. Check the computer before trying again. ${TunnelCopy.display(e.message ?: "", hostLabel)}" }
            } else {
                canRetry = true
                error = "The creation has not been confirmed. Check the computer before trying again. ${TunnelCopy.display(e.message ?: "", hostLabel)}"
            }
        } finally {
            working = false
        }
    }

    suspend fun readReceipt() {
        val operationID = pending ?: return
        if (working) return
        working = true
        canRetry = false
        notice = null
        try {
            val element = model.workspaceSection(peer, "todo.creationReceipt", buildJsonObject { put("operationId", operationID) })
            if (element is JsonNull) {
                canRetry = true
                notice = "The computer has no creation receipt yet. You can retry this same task safely."
            } else {
                confirm(TaskCreationOutcome.parse(element as JsonObject), operationID)
            }
        } catch (e: Exception) {
            error = TunnelCopy.display(e.message ?: "The request failed.", hostLabel)
        } finally {
            working = false
        }
    }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(Modifier.fillMaxSize().padding(Space.m).verticalScroll(rememberScrollState())) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("New task", style = TsType.cardTitle, color = LocalTsColors.current.textPrimary)
                    Text(hostLabel, style = TsType.caption, color = LocalTsColors.current.textSecondary)
                }
                IconButton(onClick = onDismiss) {
                    Icon(ActionIcon.Dismiss.vector, "Close", tint = LocalTsColors.current.controlGlyph)
                }
            }
            if (!supported) {
                Banner(
                    "Update $hostLabel's tokenstat to create tasks from here. Your draft stays on this device.",
                    BannerSeverity.WARNING,
                )
            }
            if (error != null) Banner(error!!, BannerSeverity.DANGER)
            if (notice != null) {
                Text(notice!!, style = TsType.caption, color = LocalTsColors.current.textSecondary)
            }
            if (outcome != null) {
                Text("Task added.", style = TsType.body, color = LocalTsColors.current.textPrimary)
                TsAccentButton(label = "Done", onClick = onDismiss)
            } else {
                TaskFields(
                    fields = fields,
                    onFields = { fields = it },
                    backends = liveBackends,
                    folders = liveFolders,
                    enabled = supported && !working && pending == null,
                )
                Spacer(Modifier.padding(top = Space.s))
                Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    if (pending != null) {
                        TsSecondaryButton(label = "Check", enabled = !working, onClick = { scope.launch { readReceipt() } })
                    }
                    if (canRetry) {
                        TsAccentButton(label = "Retry same task", enabled = !working, onClick = {
                            val operationID = pending ?: return@TsAccentButton
                            scope.launch { submit(operationID) }
                        })
                    } else if (pending == null) {
                        TsAccentButton(
                            label = if (working) "Creating…" else "Create task",
                            enabled = supported && !working && fields.validation == null,
                            onClick = {
                                val operationID = TaskOperations.creationID()
                                pending = operationID
                                scope.launch { submit(operationID) }
                            },
                        )
                    }
                }
            }
        }
    }
}

/// The exact task run, with a door into that folder's files and history.
/// Port of `ClientTaskResultView` (phone layout): header, live transcript,
/// terminal door for foreground runs, and Changes/History links.
@Composable
fun TaskRunDialog(
    model: AppViewModel,
    peer: String,
    hostLabel: String,
    runID: String,
    workspaceID: String,
    folderName: String,
    onOpenTerminal: (String) -> Unit,
    onOpenSection: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var run by remember { mutableStateOf<JsonObject?>(null) }
    var transcript by remember { mutableStateOf("") }
    var loaded by remember { mutableStateOf(false) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var attachError by remember { mutableStateOf<String?>(null) }

    suspend fun loadTranscript(id: String, live: Boolean) {
        var offset = 0L
        val builder = StringBuilder()
        while (true) {
            val chunk = runCatching {
                model.workspaceSection(peer, "automation.transcript", buildJsonObject {
                    put("id", id)
                    put("offset", offset)
                }) as JsonObject
            }.getOrNull() ?: break
            builder.append(chunk.optStr("text") ?: "")
            if (builder.length > 256 * 1024) {
                builder.delete(0, builder.length - 256 * 1024)
            }
            offset = chunk.optLong("nextOffset") ?: break
            transcript = builder.toString()
            if (!live) break
            delay(1_000)
            val fresh = runCatching {
                model.workspaceSection(peer, "automation.runs", buildJsonObject {})
            }.getOrNull()
            val updated = ((fresh as? kotlinx.serialization.json.JsonArray)
                ?.filterIsInstance<JsonObject>() ?: emptyList()).firstOrNull { it.optStr("id") == id }
            run = updated
            val status = updated?.optStr("status") ?: ""
            if (status !in setOf("starting", "queued", "running", "stopping")) break
        }
        transcript = builder.toString()
    }

    suspend fun load() {
        loading = true
        runCatching { model.workspaceSection(peer, "automation.runs", buildJsonObject {}) }
            .onSuccess { element ->
                val found = ((element as? kotlinx.serialization.json.JsonArray)
                    ?.filterIsInstance<JsonObject>() ?: emptyList()).firstOrNull { it.optStr("id") == runID }
                run = found
                loaded = true
                error = null
                if (found != null) {
                    val status = found.optStr("status") ?: ""
                    loadTranscript(runID, status in setOf("starting", "queued", "running", "stopping"))
                }
            }
            .onFailure { error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
        loading = false
    }

    LaunchedEffect(runID) { load() }

    val route = TaskResultRoute(
        runID = runID,
        workspaceID = workspaceID,
        folderName = folderName,
        hostName = hostLabel,
        folderMissing = false,
    )
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(Modifier.fillMaxSize().padding(Space.m).verticalScroll(rememberScrollState())) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    run?.optStr("name") ?: "Result",
                    style = TsType.cardTitle,
                    color = LocalTsColors.current.textPrimary,
                    modifier = Modifier.weight(1f),
                    maxLines = 1,
                )
                TextButton(onClick = onDismiss) { Text("Done") }
            }
            if (error != null) {
                Banner(error!!, BannerSeverity.DANGER)
                TsSecondaryButton(label = "Reload", small = true, onClick = { scope.launch { load() } })
            }
            if (loading && !loaded) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    CircularProgressIndicator()
                    Text("Loading result", color = LocalTsColors.current.textSecondary)
                }
            }
            val current = run
            if (current != null) {
                TsCard(title = "Run") {
                    Column(Modifier.padding(Space.m), verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                        Text(runStatusLabel(current.optStr("status") ?: ""), color = LocalTsColors.current.textPrimary)
                        Text("Agent: ${current.optStr("backend") ?: ""}", style = TsType.caption, color = LocalTsColors.current.textSecondary)
                        Text("Folder: ${route.folderLabel}", style = TsType.caption, color = LocalTsColors.current.textSecondary)
                        if ((current.optStr("status") ?: "") in setOf("starting", "queued", "running", "stopping")) {
                            Text(
                                "This run continues on $hostLabel.",
                                style = TsType.caption,
                                color = LocalTsColors.current.textSecondary,
                            )
                        }
                    }
                }
                val pty = current.optStr("ptyId")
                if (!pty.isNullOrEmpty()) {
                    TsSecondaryButton(label = "Open terminal", icon = ActionIcon.Reopen.vector, small = true, onClick = {
                        onOpenTerminal(pty)
                    })
                }
                if (attachError != null) {
                    Text(attachError!!, style = TsType.caption, color = LocalTsColors.current.danger)
                }
                TsCard(title = "Transcript") {
                    Text(
                        transcript.ifBlank {
                            val status = current.optStr("status") ?: ""
                            if (status in setOf("starting", "queued", "running", "stopping")) {
                                if (!pty.isNullOrEmpty()) "Output is in the terminal on $hostLabel." else "Waiting for output…"
                            } else "No readable output."
                        },
                        style = TsType.mono(12),
                        color = LocalTsColors.current.textPrimary,
                        modifier = Modifier.padding(Space.m),
                    )
                }
            } else if (loaded) {
                TsCard(title = "This run is unavailable") {
                    Text(
                        "It is no longer in this folder's run history. The folder's files and commits are still available below.",
                        style = TsType.caption,
                        color = LocalTsColors.current.textSecondary,
                        modifier = Modifier.padding(Space.m),
                    )
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                TsSecondaryButton(
                    label = "Changes",
                    small = true,
                    enabled = route.canReviewWorkspace,
                    onClick = { onOpenSection("Changes") },
                )
                TsSecondaryButton(
                    label = "History",
                    small = true,
                    enabled = route.canReviewWorkspace,
                    onClick = { onOpenSection("History") },
                )
            }
            if (!route.canReviewWorkspace) {
                Text(route.reviewMessage() ?: "", style = TsType.caption, color = LocalTsColors.current.textSecondary)
            } else {
                Text(route.changesCaption(), style = TsType.caption, color = LocalTsColors.current.textSecondary)
            }
        }
    }
}

private fun runStatusLabel(status: String): String = when (status) {
    "starting" -> "Starting"
    "queued" -> "Queued"
    "running" -> "Running"
    "stopping" -> "Stopping"
    "ok" -> "Done"
    "stopped" -> "Stopped"
    "error" -> "Failed"
    "interrupted" -> "Interrupted by restart"
    else -> status
}
