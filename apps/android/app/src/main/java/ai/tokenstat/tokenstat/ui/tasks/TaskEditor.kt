// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.tasks

import ai.tokenstat.tokenstat.ui.localization.L10n

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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import ai.tokenstat.tokenstat.ui.components.ForegroundEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
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
            label = { Text(L10n.text("android.taskeditor.task_title.11622e0f")) },
            textStyle = TsType.cardTitle,
        )
        OutlinedTextField(
            fields.prompt,
            { onFields(fields.copy(prompt = it)) },
            modifier = Modifier.fillMaxWidth(),
            enabled = enabled,
            label = { Text(if (fields.backend == "sh") L10n.text("android.taskeditor.command.71316697") else L10n.text("android.taskeditor.prompt.5c391238")) },
            minLines = 6,
        )
        Text(L10n.text("android.taskeditor.task_settings.b8a028c3"), style = TsType.body.copy(fontWeight = FontWeight.SemiBold), color = LocalTsColors.current.textPrimary)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
            ChoiceChip(L10n.text("android.taskeditor.uncategorized.8d40d123"), fields.workspaceID.isEmpty(), { onFields(fields.copy(workspaceID = "")) })
            folders.forEach { folder ->
                ChoiceChip(folder.name.ifBlank { folder.id }, fields.workspaceID == folder.id, { onFields(fields.copy(workspaceID = folder.id)) })
            }
            if (fields.workspaceID.isNotEmpty() && folders.none { it.id == fields.workspaceID }) {
                ChoiceChip(L10n.text("android.taskeditor.unavailable_folder.6454a349"), true, {})
            }
        }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
            listOf("low" to L10n.text("android.taskeditor.low.f793de20"), "normal" to L10n.text("android.taskeditor.normal.a7248eeb"), "high" to L10n.text("android.taskeditor.high.c4ebc6d4")).forEach { (value, label) ->
                ChoiceChip(label, fields.priority == value, { onFields(fields.copy(priority = value)) })
            }
        }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
            ChoiceChip(L10n.text("android.taskeditor.choose_later.64f99c1c"), fields.backend.isEmpty(), { onFields(fields.copy(backend = "", model = "", effort = "")) })
            backends.forEach { backend ->
                ChoiceChip(backend.label.ifBlank { backend.id }, fields.backend == backend.id, {
                    if (backend.id != fields.backend) onFields(fields.copy(backend = backend.id, model = "", effort = ""))
                })
            }
            if (fields.backend.isNotEmpty() && backends.none { it.id == fields.backend }) {
                ChoiceChip(L10n.text("android.taskeditor.0_unavailable.1212b25c", "${fields.backend}"), true, {})
            }
        }
        val backend = backends.firstOrNull { it.id == fields.backend }
        if (backend != null && (backend.models.isNotEmpty() || fields.model.isNotEmpty())) {
            val options = (backend.models + listOf(fields.model).filter { it.isNotEmpty() }).distinct()
            FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                ChoiceChip(L10n.text("android.taskeditor.default.21b111cb"), fields.model.isEmpty(), { onFields(fields.copy(model = "")) })
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
                    L10n.text("android.taskeditor.this_computer_does_not_list_the_saved_mode.479cd2e2"),
                    style = TsType.caption,
                    color = LocalTsColors.current.textSecondary,
                )
            }
        }
        if (backend != null && (backend.efforts.isNotEmpty() || fields.effort.isNotEmpty())) {
            val options = (listOf("") + backend.efforts + listOf(fields.effort).filter { it.isNotEmpty() }).distinct()
            FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                options.forEach { effort ->
                    ChoiceChip(if (effort.isEmpty()) L10n.text("android.taskeditor.default.21b111cb") else effort, fields.effort == effort, { onFields(fields.copy(effort = effort)) })
                }
            }
        }
        BrandToggleChip(L10n.text("android.taskeditor.no_time_limit.436b4b94"), fields.noTimeLimit, { onFields(fields.copy(noTimeLimit = !fields.noTimeLimit)) })
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
                label = { Text(L10n.text("android.taskeditor.time_limit.e592a9ca")) },
            )
            FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                ChoiceChip(L10n.text("android.taskeditor.minutes.4f846a84"), fields.budgetUnit == "minutes", { onFields(fields.copy(budgetUnit = "minutes")) })
                ChoiceChip(L10n.text("android.taskeditor.seconds.381a8e96"), fields.budgetUnit == "seconds", { onFields(fields.copy(budgetUnit = "seconds")) })
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
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        TaskEditorScreen(
            model = model,
            peer = peer,
            hostLabel = hostLabel,
            protocol = protocol,
            cardId = cardId,
            backends = backends,
            folders = folders,
            onViewRun = onViewRun,
            onOpenTerminal = onOpenTerminal,
            onSaved = onSaved,
            onBack = onDismiss,
        )
    }
}

/// The task detail editor as a full page on the app background.
@Composable
fun TaskEditorScreen(
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
    onBack: () -> Unit,
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
                error = L10n.text("android.taskeditor.this_task_was_deleted_on_the_computer_your.d9041f3d")
            } else if (card.revision == null) {
                error = L10n.text("android.taskeditor.this_computer_did_not_return_the_task_s_re.ec042ca5")
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
            error = TunnelCopy.display(e.message ?: L10n.text("android.taskeditor.the_request_failed.db4fb447"), hostLabel)
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
                error = L10n.text("android.taskeditor.this_task_was_deleted_on_the_computer_your.d9041f3d")
            } else if (fresh.revision == null) {
                error = L10n.text("android.taskeditor.this_computer_did_not_return_the_task_s_re.ec042ca5")
            } else {
                val base = baseline
                val draft = fields
                error = null
                if (base != null && draft != null) {
                    if (pendingEdit) {
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
                            if (!conflict) error = L10n.text("android.taskeditor.the_task_has_not_changed_your_draft_is_rea.c2632d0f")
                        }
                    } else if (fresh.revision != base.revision) {
                        if (!draft.matches(base)) {
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
            error = TunnelCopy.display(e.message ?: L10n.text("android.taskeditor.the_request_failed.db4fb447"), hostLabel)
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
            error = L10n.text("android.taskeditor.check_the_saved_task_before_trying_again_y.5af9adad", "${TunnelCopy.display(e.message ?: "", hostLabel)}")
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
            error = L10n.text("android.taskeditor.the_run_result_is_not_confirmed_check_this.b7631660", "${TunnelCopy.display(e.message ?: "", hostLabel)}")
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
                error = L10n.text("android.taskeditor.the_computer_has_not_accepted_this_run_req.956da73e")
            } else {
                acceptOutcome(TaskRunOutcome.parse(element as JsonObject), submission)
            }
        } catch (e: Exception) {
            error = L10n.text("android.taskeditor.the_run_result_is_still_unavailable_your_r.294ee202", "${TunnelCopy.display(e.message ?: "", hostLabel)}")
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
            error = L10n.text("android.taskeditor.the_stop_was_not_confirmed_reload_this_tas.ea360237", "${TunnelCopy.display(e.message ?: "", hostLabel)}")
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

    BackHandler { onBack() }
    Column(
        Modifier
            .fillMaxSize()
            .background(LocalTsColors.current.background)
            .padding(Space.m)
            .verticalScroll(rememberScrollState()),
    ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(L10n.text("android.taskeditor.task.4bc74b21"), style = TsType.cardTitle, color = LocalTsColors.current.textPrimary)
                    Text(hostLabel, style = TsType.caption, color = LocalTsColors.current.textSecondary)
                }
                IconButton(onClick = onBack) {
                    Icon(ActionIcon.Back.vector, L10n.text("common.back"), tint = LocalTsColors.current.controlGlyph)
                }
            }
            if (error != null) {
                Banner(error!!, BannerSeverity.DANGER)
                if (!pendingEdit) {
                    TsSecondaryButton(label = L10n.text("android.taskeditor.reload_task.58d8bf39"), small = true, onClick = { scope.launch { load() } })
                }
            }
            if (working) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    CircularProgressIndicator()
                    Text(L10n.text("android.taskeditor.updating_task.5befd393"), color = LocalTsColors.current.textSecondary)
                }
            }
            if (loaded && !supportsExecution) {
                Text(
                    L10n.text("android.taskeditor.update_0_s_tokenstat_to_run_and_stop_tasks.597ff76e", "${hostLabel}"),
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
                            if (delegate.isRunning) delegate.label else L10n.text("android.taskeditor.last_run_0.f8973a05", "${delegate.label}"),
                            style = TsType.body.copy(fontWeight = FontWeight.SemiBold),
                            color = LocalTsColors.current.textPrimary,
                        )
                        val runError = delegate.error
                        if (!runError.isNullOrEmpty()) {
                            Text(runError, style = TsType.caption, color = LocalTsColors.current.danger, maxLines = 3)
                        } else {
                            Text(
                                if (delegate.isRunning) L10n.text("android.taskeditor.this_run_continues_on_the_connected_comput.5bbf94b0") else L10n.text("android.taskeditor.the_result_remains_linked_to_this_task.54407ca7"),
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
                        Text(L10n.text("android.taskeditor.changed_on_the_computer.aefb92cf"), style = TsType.body.copy(fontWeight = FontWeight.SemiBold), color = LocalTsColors.current.textPrimary)
                        Text(snapshot.title, color = LocalTsColors.current.textPrimary)
                        Text(snapshot.notes, color = LocalTsColors.current.textPrimary)
                        Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                            TsSecondaryButton(label = L10n.text("android.taskeditor.use_computer_version.f0d6599f"), small = true, onClick = {
                                baseline = snapshot
                                fields = TaskEditorDraft.fromCard(snapshot)
                                conflict = false
                                error = null
                            })
                            TsSecondaryButton(label = L10n.text("android.taskeditor.keep_my_draft.cdb80bb9"), small = true, onClick = {
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
                    TsAccentButton(label = L10n.text("android.taskeditor.check_saved_task.6d057bda"), enabled = !working, onClick = {
                        scope.launch { refresh(); onSaved() }
                    })
                }
                pending != null -> {
                    Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                        TsSecondaryButton(label = L10n.text("android.taskeditor.check_run.cece2401"), enabled = !working, onClick = {
                            scope.launch {
                                reconcileRun()
                                openOutcome(lastRun)
                            }
                        })
                        TsAccentButton(label = L10n.text("android.taskeditor.retry_same_request.16003a1a"), enabled = !working, onClick = {
                            scope.launch { openOutcome(submitRun(pending)) }
                        })
                    }
                }
                else -> {
                    if (delegate?.isRunning == true) {
                        Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                            TsSecondaryButton(
                                label = if (delegate.status == "stopping") L10n.text("android.taskeditor.stopping.bbe85741") else L10n.text("common.stop"),
                                icon = ActionIcon.Stop.vector,
                                enabled = supportsExecution && !working,
                                onClick = { scope.launch { stop(); onSaved() } },
                            )
                            TsAccentButton(label = L10n.text("android.taskeditor.view_run.aaf7fccc"), icon = ActionIcon.Preview.vector, onClick = {
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
                            TsSecondaryButton(label = L10n.text("android.taskeditor.view_last_result.1e6894ea"), icon = ActionIcon.Preview.vector, onClick = {
                                onViewRun(delegate.runId, base?.workspaceID ?: "")
                            })
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                            TsSecondaryButton(
                                label = L10n.text("android.taskeditor.run_in_background.c7b156d3"),
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
                                label = L10n.text("android.taskeditor.run_in_terminal.f0b4acbf"),
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
                        label = L10n.text("android.taskeditor.save_task.42a9eb31"),
                        icon = ActionIcon.Save.vector,
                        enabled = canSave,
                        onClick = { scope.launch { save() } },
                    )
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
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        TaskCreateScreen(
            model = model,
            peer = peer,
            hostLabel = hostLabel,
            protocol = protocol,
            initialFolder = initialFolder,
            defaultBudget = defaultBudget,
            backends = backends,
            folders = folders,
            onCreated = onCreated,
            onBack = onDismiss,
        )
    }
}

/// Task creation as a full page on the app background.
@Composable
fun TaskCreateScreen(
    model: AppViewModel,
    peer: String,
    hostLabel: String,
    protocol: Long?,
    initialFolder: String,
    defaultBudget: Long,
    backends: List<BackendRef>,
    folders: List<FolderRef>,
    onCreated: () -> Unit,
    onBack: () -> Unit,
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
            error = L10n.text("android.taskeditor.the_computer_returned_a_different_creation.61eecd53")
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
                    .onFailure { error = L10n.text("android.taskeditor.the_creation_has_not_been_confirmed_check.2a4e0d3e", "${TunnelCopy.display(e.message ?: "", hostLabel)}") }
            } else {
                canRetry = true
                error = L10n.text("android.taskeditor.the_creation_has_not_been_confirmed_check.2a4e0d3e", "${TunnelCopy.display(e.message ?: "", hostLabel)}")
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
                notice = L10n.text("android.taskeditor.the_computer_has_no_creation_receipt_yet_y.9772be6d")
            } else {
                confirm(TaskCreationOutcome.parse(element as JsonObject), operationID)
            }
        } catch (e: Exception) {
            error = TunnelCopy.display(e.message ?: L10n.text("android.taskeditor.the_request_failed.db4fb447"), hostLabel)
        } finally {
            working = false
        }
    }

    BackHandler { onBack() }
    Column(
        Modifier
            .fillMaxSize()
            .background(LocalTsColors.current.background)
            .padding(Space.m)
            .verticalScroll(rememberScrollState()),
    ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(L10n.text("android.taskeditor.new_task.3e992276"), style = TsType.cardTitle, color = LocalTsColors.current.textPrimary)
                    Text(hostLabel, style = TsType.caption, color = LocalTsColors.current.textSecondary)
                }
                IconButton(onClick = onBack) {
                    Icon(ActionIcon.Back.vector, L10n.text("common.back"), tint = LocalTsColors.current.controlGlyph)
                }
            }
            if (!supported) {
                Banner(
                    L10n.text("android.taskeditor.update_0_s_tokenstat_to_create_tasks_from.e02717bd", "${hostLabel}"),
                    BannerSeverity.WARNING,
                )
            }
            if (error != null) Banner(error!!, BannerSeverity.DANGER)
            if (notice != null) {
                Text(notice!!, style = TsType.caption, color = LocalTsColors.current.textSecondary)
            }
            if (outcome != null) {
                Text(L10n.text("android.taskeditor.task_added.d37be00e"), style = TsType.body, color = LocalTsColors.current.textPrimary)
                TsAccentButton(label = L10n.text("common.done"), onClick = onBack)
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
                        TsSecondaryButton(label = L10n.text("android.taskeditor.check.9d60841e"), enabled = !working, onClick = { scope.launch { readReceipt() } })
                    }
                    if (canRetry) {
                        TsAccentButton(label = L10n.text("android.taskeditor.retry_same_task.895a4f9d"), enabled = !working, onClick = {
                            val operationID = pending ?: return@TsAccentButton
                            scope.launch { submit(operationID) }
                        })
                    } else if (pending == null) {
                        TsAccentButton(
                            label = if (working) L10n.text("android.taskeditor.creating.c79ed949") else L10n.text("android.taskeditor.create_task.6f541e1b"),
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
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        TaskRunScreen(
            model = model,
            peer = peer,
            hostLabel = hostLabel,
            runID = runID,
            workspaceID = workspaceID,
            folderName = folderName,
            onOpenTerminal = onOpenTerminal,
            onOpenSection = onOpenSection,
            onBack = onDismiss,
        )
    }
}

/// The exact task run as a full page on the app background.
@Composable
fun TaskRunScreen(
    model: AppViewModel,
    peer: String,
    hostLabel: String,
    runID: String,
    workspaceID: String,
    folderName: String,
    onOpenTerminal: (String) -> Unit,
    onOpenSection: (String) -> Unit,
    onBack: () -> Unit,
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
            .onFailure { error = TunnelCopy.display(it.message ?: L10n.text("android.taskeditor.the_request_failed.db4fb447"), hostLabel) }
        loading = false
    }

    ForegroundEffect(peer, runID) { load() }

    val route = TaskResultRoute(
        runID = runID,
        workspaceID = workspaceID,
        folderName = folderName,
        hostName = hostLabel,
        folderMissing = false,
    )
    BackHandler { onBack() }
    Column(
        Modifier
            .fillMaxSize()
            .background(LocalTsColors.current.background)
            .padding(Space.m)
            .verticalScroll(rememberScrollState()),
    ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onBack) {
                    Icon(ActionIcon.Back.vector, L10n.text("common.back"), tint = LocalTsColors.current.controlGlyph)
                }
                Text(
                    run?.optStr("name") ?: L10n.text("android.taskeditor.result.6e7d50e8"),
                    style = TsType.cardTitle,
                    color = LocalTsColors.current.textPrimary,
                    modifier = Modifier.weight(1f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                TextButton(onClick = onBack) { Text(L10n.text("common.done")) }
            }
            if (error != null) {
                Banner(error!!, BannerSeverity.DANGER)
                TsSecondaryButton(label = L10n.text("android.taskeditor.reload.bdc090ec"), small = true, onClick = { scope.launch { load() } })
            }
            if (loading && !loaded) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    CircularProgressIndicator()
                    Text(L10n.text("android.taskeditor.loading_result.9f43a300"), color = LocalTsColors.current.textSecondary)
                }
            }
            val current = run
            if (current != null) {
                TsCard(title = L10n.text("common.run")) {
                    Column(Modifier.padding(Space.m), verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                        Text(runStatusLabel(current.optStr("status") ?: ""), color = LocalTsColors.current.textPrimary)
                        Text(L10n.text("android.taskeditor.agent_0.10f2263c", "${current.optStr("backend") ?: ""}"), style = TsType.caption, color = LocalTsColors.current.textSecondary)
                        Text(L10n.text("android.taskeditor.folder_0.164efc52", "${route.folderLabel}"), style = TsType.caption, color = LocalTsColors.current.textSecondary)
                        if ((current.optStr("status") ?: "") in setOf("starting", "queued", "running", "stopping")) {
                            Text(
                                L10n.text("android.taskeditor.this_run_continues_on_0.f887356d", "${hostLabel}"),
                                style = TsType.caption,
                                color = LocalTsColors.current.textSecondary,
                            )
                        }
                    }
                }
                val pty = current.optStr("ptyId")
                if (!pty.isNullOrEmpty()) {
                    TsSecondaryButton(label = L10n.text("android.taskeditor.open_terminal.acb1f43d"), icon = ActionIcon.Reopen.vector, small = true, onClick = {
                        onOpenTerminal(pty)
                    })
                }
                if (attachError != null) {
                    Text(attachError!!, style = TsType.caption, color = LocalTsColors.current.danger)
                }
                TsCard(title = L10n.text("android.taskeditor.transcript.721164f0")) {
                    Text(
                        transcript.ifBlank {
                            val status = current.optStr("status") ?: ""
                            if (status in setOf("starting", "queued", "running", "stopping")) {
                                if (!pty.isNullOrEmpty()) L10n.text("android.taskeditor.output_is_in_the_terminal_on_0.6e84e78a", "${hostLabel}") else L10n.text("android.taskeditor.waiting_for_output.f05fefe2")
                            } else L10n.text("android.taskeditor.no_readable_output.cd218ba3")
                        },
                        style = TsType.mono(12),
                        color = LocalTsColors.current.textPrimary,
                        modifier = Modifier.padding(Space.m),
                    )
                }
            } else if (loaded) {
                TsCard(title = L10n.text("android.taskeditor.this_run_is_unavailable.5bef28b2")) {
                    Text(
                        L10n.text("android.taskeditor.it_is_no_longer_in_this_folder_s_run_histo.dad904f6"),
                        style = TsType.caption,
                        color = LocalTsColors.current.textSecondary,
                        modifier = Modifier.padding(Space.m),
                    )
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                TsSecondaryButton(
                    label = L10n.text("android.taskeditor.changes.bbd4b6a8"),
                    small = true,
                    enabled = route.canReviewWorkspace,
                    onClick = { onOpenSection("Changes") },
                )
                TsSecondaryButton(
                    label = L10n.text("common.history"),
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

private fun runStatusLabel(status: String): String = when (status) {
    "starting" -> L10n.text("android.taskeditor.starting.aeed4d26")
    "queued" -> L10n.text("common.queued")
    "running" -> L10n.text("common.running")
    "stopping" -> L10n.text("android.taskeditor.stopping.a71ee1d4")
    "ok" -> L10n.text("common.done")
    "stopped" -> L10n.text("android.taskeditor.stopped.1a4f630a")
    "error" -> L10n.text("common.failed")
    "interrupted" -> L10n.text("android.taskeditor.interrupted_by_restart.012812fe")
    else -> status
}
