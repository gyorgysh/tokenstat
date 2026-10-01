// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.automations

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
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
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
import ai.tokenstat.tokenstat.ui.tasks.BackendRef
import ai.tokenstat.tokenstat.ui.tasks.FolderRef
import ai.tokenstat.tokenstat.ui.tasks.TaskOperations
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/// New and Edit automation in one Writing/Settings editor. Port of
/// `AutomationEditorView` plus `AutomationFieldsView`.
///
/// Save rules, ported from `AutomationEditorSession`: on protocol 21+
/// hosts the edit is `automation.edit` with the baseline revision and one
/// checked edit can win, with the computer-version conflict flow; below
/// that it is `automation.update` with the overwrite notice. Creation is
/// `automation.createOnce` with a receipt check and retry-same where the
/// host offers it, plain `automation.create` below that.
@Composable
fun AutomationEditorDialog(
    model: AppViewModel,
    peer: String,
    hostLabel: String,
    protocol: Long?,
    workspaceID: String,
    folderName: String,
    existing: AutomationJob?,
    backends: List<BackendRef>,
    defaultBudget: Long,
    timezone: String,
    onSaved: () -> Unit,
    onDismiss: () -> Unit,
) {
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        AutomationEditorScreen(
            model = model,
            peer = peer,
            hostLabel = hostLabel,
            protocol = protocol,
            workspaceID = workspaceID,
            folderName = folderName,
            existing = existing,
            backends = backends,
            defaultBudget = defaultBudget,
            timezone = timezone,
            onSaved = onSaved,
            onBack = onDismiss,
        )
    }
}

/// The automation editor as a full page on the app background.
@Composable
fun AutomationEditorScreen(
    model: AppViewModel,
    peer: String,
    hostLabel: String,
    protocol: Long?,
    workspaceID: String,
    folderName: String,
    existing: AutomationJob?,
    template: AutomationTemplate? = null,
    backends: List<BackendRef>,
    defaultBudget: Long,
    timezone: String,
    onSaved: () -> Unit,
    onBack: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val supportsReceipts = HostContracts.supportsAutomationReceipts(protocol)
    var baseline by remember { mutableStateOf(existing) }
    var fields by remember {
        mutableStateOf(existing?.let(AutomationEditorDraft::fromJob) ?: template?.draft(workspaceID) ?: AutomationEditorDraft.blank(workspaceID, defaultBudget))
    }
    var folders by remember { mutableStateOf<List<FolderRef>>(emptyList()) }
    var loaded by remember { mutableStateOf(false) }
    var working by remember { mutableStateOf(false) }
    var conflict by remember { mutableStateOf(false) }
    var missing by remember { mutableStateOf(false) }
    var overwriteNotice by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var notice by remember { mutableStateOf<String?>(null) }
    var pendingEdit by remember { mutableStateOf(false) }
    var pendingCreation by remember { mutableStateOf<String?>(null) }
    var canRetryCreate by remember { mutableStateOf(false) }
    var created by remember { mutableStateOf<AutomationJob?>(null) }
    var confirmingDelete by remember { mutableStateOf(false) }

    suspend fun readCurrent(id: String): AutomationJob? {
        val element = model.workspaceSection(peer, "automation.list", buildJsonObject {})
        return ((element as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList())
            .map(AutomationJob::parse).firstOrNull { it.id == id }
    }

    suspend fun load() {
        working = true
        runCatching { model.workspaceSection(peer, "workspace.list", buildJsonObject {}) }
            .onSuccess { element ->
                folders = ((element as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()).map(FolderRef::parse)
            }
        val id = baseline?.id
        if (id != null) {
            runCatching { readCurrent(id) }
                .onSuccess { fresh ->
                    if (fresh == null) {
                        missing = true
                        error = L10n.text("android.automationeditor.this_job_was_deleted_on_the_computer_your.282b1669")
                    } else {
                        baseline = fresh
                        error = null
                    }
                }
                .onFailure { error = TunnelCopy.display(it.message ?: L10n.text("android.automationeditor.the_request_failed.db4fb447"), hostLabel) }
        }
        loaded = true
        working = false
    }

    suspend fun refresh() {
        val id = baseline?.id ?: return
        if (working) return
        working = true
        try {
            val fresh = readCurrent(id)
            if (fresh == null) {
                missing = true
                error = L10n.text("android.automationeditor.this_job_was_deleted_on_the_computer_your.282b1669")
            } else {
                val base = baseline
                error = null
                if (supportsReceipts) {
                    if (pendingEdit) {
                        if (fields.matches(fresh)) {
                            baseline = fresh
                            pendingEdit = false
                            conflict = false
                        } else {
                            pendingEdit = false
                            conflict = base != null && fresh.revision != base.revision
                            if (!conflict) error = L10n.text("android.automationeditor.the_job_has_not_changed_your_draft_is_read.d675494f")
                        }
                    } else if (base != null && fresh.revision != base.revision) {
                        if (fields.matches(base)) {
                            baseline = fresh
                            fields = AutomationEditorDraft.fromJob(fresh)
                            conflict = false
                        } else {
                            conflict = true
                        }
                    }
                } else if (base != null && !fields.matches(base) && !fields.matches(fresh)) {
                    overwriteNotice = true
                }
            }
        } catch (e: Exception) {
            error = TunnelCopy.display(e.message ?: L10n.text("android.automationeditor.the_request_failed.db4fb447"), hostLabel)
        } finally {
            working = false
        }
    }

    suspend fun applySaved(updated: AutomationJob) {
        baseline = updated
        fields = AutomationEditorDraft.fromJob(updated)
        pendingEdit = false
        conflict = false
        overwriteNotice = false
        error = null
        notice = L10n.text("android.automationeditor.saved_0.d851298f", "${updated.name}")
        onSaved()
    }

    suspend fun save() {
        val base = baseline ?: return
        working = true
        try {
            val job = fields.makeJob(
                id = base.id,
                enabled = base.enabled,
                lastRunAtMs = base.lastRunAtMs,
                lastRunID = base.lastRunID,
                revision = base.revision,
            )
            if (supportsReceipts) {
                pendingEdit = true
                val element = model.workspaceSection(peer, "automation.edit", buildJsonObject {
                    put("job", job.toJson())
                    put("expectedRevision", base.revision)
                })
                applySaved(AutomationJob.parse(element as JsonObject))
            } else {
                val element = model.workspaceSection(peer, "automation.update", buildJsonObject {
                    put("job", job.toJson())
                })
                applySaved(AutomationJob.parse(element as JsonObject))
            }
        } catch (e: Exception) {
            val message = e.message ?: ""
            if (message.contains("This job changed since you opened it")) {
                pendingEdit = false
                working = false
                refresh()
                return
            }
            error = TunnelCopy.display(message.ifBlank { L10n.text("android.automationeditor.the_request_failed.db4fb447") }, hostLabel)
        } finally {
            working = false
        }
    }

    fun confirmCreation(outcome: AutomationCreationOutcome, operationID: String) {
        if (outcome.operationID != operationID) {
            error = L10n.text("android.automationeditor.the_computer_returned_a_different_creation.540bca8e")
            return
        }
        created = outcome.job
        pendingCreation = null
        canRetryCreate = false
        error = null
        notice = L10n.text("android.automationeditor.created_0.558d3d2c", "${outcome.job?.name ?: L10n.text("android.automationeditor.the_job.b8fac54e")}")
        onSaved()
    }

    suspend fun submitCreation(operationID: String) {
        canRetryCreate = false
        error = null
        notice = null
        working = true
        try {
            val job = fields.makeJob(id = "", enabled = true)
            val element = model.workspaceSection(peer, "automation.createOnce", buildJsonObject {
                put("job", job.toJson())
                put("operationId", operationID)
            })
            confirmCreation(AutomationCreationOutcome.parse(element as JsonObject), operationID)
        } catch (e: Exception) {
            val receipt = runCatching {
                model.workspaceSection(peer, "automation.creationReceipt", buildJsonObject { put("operationId", operationID) })
            }.getOrNull()
            if (receipt != null && receipt !is JsonNull) {
                runCatching { confirmCreation(AutomationCreationOutcome.parse(receipt as JsonObject), operationID) }
                    .onFailure { error = L10n.text("android.automationeditor.the_computer_did_not_confirm_this_job_chec.8bc0a151") }
            } else {
                canRetryCreate = true
                error = L10n.text("android.automationeditor.the_computer_did_not_confirm_this_job_chec.8bc0a151")
            }
        } finally {
            working = false
        }
    }

    suspend fun readCreation() {
        val operationID = pendingCreation ?: return
        if (working) return
        working = true
        canRetryCreate = false
        notice = null
        try {
            val element = model.workspaceSection(peer, "automation.creationReceipt", buildJsonObject {
                put("operationId", operationID)
            })
            if (element is JsonNull) {
                canRetryCreate = true
                notice = L10n.text("android.automationeditor.the_computer_has_no_creation_receipt_yet_y.7dc58baa")
            } else {
                confirmCreation(AutomationCreationOutcome.parse(element as JsonObject), operationID)
            }
        } catch (e: Exception) {
            error = TunnelCopy.display(e.message ?: L10n.text("android.automationeditor.the_request_failed.db4fb447"), hostLabel)
        } finally {
            working = false
        }
    }

    suspend fun createPlain() {
        working = true
        try {
            val job = fields.makeJob(id = "", enabled = true)
            val element = model.workspaceSection(peer, "automation.create", buildJsonObject {
                put("job", job.toJson())
            })
            created = AutomationJob.parse(element as JsonObject)
            error = null
            notice = L10n.text("android.automationeditor.created_0.558d3d2c", "${created?.name ?: L10n.text("android.automationeditor.the_job.b8fac54e")}")
            onSaved()
        } catch (e: Exception) {
            error = L10n.text("android.automationeditor.the_computer_did_not_confirm_this_job_chec.8f3afcaa")
        } finally {
            working = false
        }
    }

    suspend fun delete() {
        val id = baseline?.id ?: return
        working = true
        runCatching {
            model.workspaceSection(peer, "automation.remove", buildJsonObject { put("id", id) })
        }.onSuccess {
            confirmingDelete = false
            notice = L10n.text("android.automationeditor.deleted.297db64a")
            onSaved()
            onBack()
        }.onFailure {
            error = TunnelCopy.display(it.message ?: L10n.text("android.automationeditor.the_request_failed.db4fb447"), hostLabel)
        }
        working = false
    }

    LaunchedEffect(baseline?.id) { load() }

    val base = baseline
    val isCreate = base == null && created == null
    val dirty = if (base != null) !fields.matches(base) else fields.name.isNotEmpty() || fields.prompt.isNotEmpty() || fields.schedule.scheduleKind != ScheduleKind.ONCE
    val canSave = loaded && !working && !missing && !conflict && !pendingEdit && created == null && pendingCreation == null && fields.validation == null && dirty
    val canCreate = isCreate && loaded && !working && pendingCreation == null && created == null && fields.validation == null

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
                Column(Modifier.weight(1f)) {
                    Text(
                        if (isCreate) L10n.text("android.automationeditor.new_automation.db87a63d") else L10n.text("android.automationeditor.automation.d909750b"),
                        style = TsType.cardTitle,
                        color = LocalTsColors.current.textPrimary,
                    )
                    Text(folderName.ifBlank { hostLabel }, style = TsType.caption, color = LocalTsColors.current.textSecondary)
                }
            }
            if (error != null) {
                Banner(error!!, BannerSeverity.DANGER)
                if (base != null && !pendingEdit) {
                    TsSecondaryButton(label = L10n.text("android.automationeditor.reload_job.8a35350e"), small = true, onClick = { scope.launch { load() } })
                }
            }
            if (notice != null) {
                Text(notice!!, style = TsType.caption, color = LocalTsColors.current.textSecondary)
            }
            if (working && !loaded) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    CircularProgressIndicator()
                    Text(L10n.text("android.automationeditor.loading_job.04a276e4"), color = LocalTsColors.current.textSecondary)
                }
            }
            Text(L10n.text("android.automationeditor.writing.a8bfae3e"), style = TsType.body.copy(fontWeight = FontWeight.SemiBold), color = LocalTsColors.current.textPrimary)
            OutlinedTextField(
                fields.name,
                { fields = fields.copy(name = it) },
                modifier = Modifier.fillMaxWidth(),
                enabled = !working && pendingCreation == null,
                label = { Text(L10n.text("android.automationeditor.name.dcd1d522")) },
            )
            OutlinedTextField(
                fields.prompt,
                { fields = fields.copy(prompt = it) },
                modifier = Modifier.fillMaxWidth(),
                enabled = !working && pendingCreation == null,
                label = { Text(L10n.text("android.automationeditor.prompt.5c391238")) },
                minLines = 6,
            )
            Text(L10n.text("common.settings"), style = TsType.body.copy(fontWeight = FontWeight.SemiBold), color = LocalTsColors.current.textPrimary)
            AutomationFolderChips(fields = fields, onFields = { fields = it }, folders = folders, lockedFolder = workspaceID)
            AutomationBackendChips(fields = fields, onFields = { fields = it }, backends = backends)
            ScheduleEditor(
                schedule = fields.schedule,
                onSchedule = { fields = fields.copy(schedule = it) },
                timezoneCaption = HostScheduleClock.timeCaption(hostLabel, timezone.ifBlank { null }),
                enabled = !working && pendingCreation == null,
            )
            Text(L10n.text("android.automationeditor.time_limit.e592a9ca"), style = TsType.body.copy(fontWeight = FontWeight.SemiBold), color = LocalTsColors.current.textPrimary)
            BrandToggleChip(L10n.text("android.automationeditor.no_time_limit.436b4b94"), fields.budget.noTimeLimit, { fields = fields.copy(budget = fields.budget.copy(noTimeLimit = !fields.budget.noTimeLimit)) })
            if (!fields.budget.noTimeLimit) {
                TimeLimitChips(
                    minutesText = fields.budget.budgetMinutes,
                    noLimit = false,
                    onMinutesChange = { fields = fields.copy(budget = fields.budget.copy(budgetMinutes = it)) },
                    onNoLimitChange = {},
                )
                OutlinedTextField(
                    fields.budget.budgetMinutes,
                    { fields = fields.copy(budget = fields.budget.copy(budgetMinutes = it)) },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !working && pendingCreation == null,
                    label = { Text(L10n.text("android.automationeditor.minutes.4f846a84")) },
                )
            }
            if (fields.validation != null) {
                Text(fields.validation!!, style = TsType.caption, color = LocalTsColors.current.danger)
            }
            if (conflict && base != null) {
                TsCard {
                    Column(Modifier.padding(Space.m), verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                        Text(L10n.text("android.automationeditor.changed_on_the_computer.aefb92cf"), style = TsType.body.copy(fontWeight = FontWeight.SemiBold), color = LocalTsColors.current.textPrimary)
                        Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                            TsSecondaryButton(label = L10n.text("android.automationeditor.use_computer_version.f0d6599f"), small = true, onClick = {
                                scope.launch {
                                    val fresh = readCurrent(base.id)
                                    if (fresh != null) {
                                        baseline = fresh
                                        fields = AutomationEditorDraft.fromJob(fresh)
                                    }
                                    conflict = false
                                    error = null
                                }
                            })
                            TsSecondaryButton(label = L10n.text("android.automationeditor.keep_my_draft.cdb80bb9"), small = true, onClick = {
                                scope.launch {
                                    val fresh = readCurrent(base.id)
                                    if (fresh != null) baseline = fresh
                                    conflict = false
                                    error = null
                                }
                            })
                        }
                    }
                }
            }
            if (!supportsReceipts && overwriteNotice) {
                Text(
                    L10n.text("android.automationeditor.this_job_also_changed_on_the_computer_savi.b2db22f7"),
                    style = TsType.caption,
                    color = LocalTsColors.current.textSecondary,
                )
            }
            Spacer(Modifier.padding(top = Space.s))
            if (created != null) {
                TsAccentButton(label = L10n.text("common.done"), onClick = onBack)
            } else if (pendingCreation != null) {
                Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    TsSecondaryButton(label = L10n.text("android.automationeditor.check.9d60841e"), enabled = !working, onClick = { scope.launch { readCreation() } })
                    if (canRetryCreate) {
                        TsAccentButton(label = L10n.text("android.automationeditor.retry_same_job.f5b790fc"), enabled = !working, onClick = {
                            val operationID = pendingCreation ?: return@TsAccentButton
                            scope.launch { submitCreation(operationID) }
                        })
                    }
                }
            } else if (isCreate) {
                TsAccentButton(
                    label = if (working) L10n.text("android.automationeditor.creating.c79ed949") else L10n.text("android.automationeditor.create_job.b7968423"),
                    enabled = canCreate,
                    onClick = {
                        if (supportsReceipts) {
                            val operationID = TaskOperations.automationCreationID()
                            pendingCreation = operationID
                            scope.launch { submitCreation(operationID) }
                        } else {
                            scope.launch { createPlain() }
                        }
                    },
                )
            } else {
                Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    TsAccentButton(label = L10n.text("android.automationeditor.save_job.f4b557c0"), enabled = canSave, onClick = { scope.launch { save() } })
                    TsSecondaryButton(label = L10n.text("common.delete"), enabled = !working, onClick = { confirmingDelete = true })
                }
            }
        }
    if (confirmingDelete && base != null) {
        AlertDialog(
            onDismissRequest = { confirmingDelete = false },
            title = { Text(L10n.text("android.automationeditor.delete_0.dc6c5ae4", "${base.name}")) },
            text = { Text(L10n.text("android.automationeditor.the_schedule_goes_with_it_runs_it_already.a4efc8fe")) },
            confirmButton = { Button(onClick = { scope.launch { delete() } }) { Text(L10n.text("common.delete")) } },
            dismissButton = { TextButton(onClick = { confirmingDelete = false }) { Text(L10n.text("common.cancel")) } },
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun AutomationFolderChips(
    fields: AutomationEditorDraft,
    onFields: (AutomationEditorDraft) -> Unit,
    folders: List<FolderRef>,
    lockedFolder: String,
) {
    FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
        ChoiceChip(L10n.text("android.automationeditor.uncategorized.8d40d123"), fields.workspaceID.isEmpty(), { onFields(fields.copy(workspaceID = "")) })
        folders.forEach { folder ->
            ChoiceChip(folder.name.ifBlank { folder.id }, fields.workspaceID == folder.id, { onFields(fields.copy(workspaceID = folder.id)) })
        }
        if (fields.workspaceID.isNotEmpty() && fields.workspaceID != lockedFolder && folders.none { it.id == fields.workspaceID }) {
            ChoiceChip(L10n.text("android.automationeditor.unavailable_folder.6454a349"), true, {})
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun AutomationBackendChips(
    fields: AutomationEditorDraft,
    onFields: (AutomationEditorDraft) -> Unit,
    backends: List<BackendRef>,
) {
    val options = (backends + listOfNotNull(
        BackendRef(id = fields.backend, label = L10n.text("android.automationeditor.0_unavailable.1212b25c", "${fields.backend}")).takeIf { fields.backend.isNotEmpty() && backends.none { it.id == fields.backend } },
    )).sortedBy { if (it.id == "sh") 1 else 0 }
    FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
        options.forEach { backend ->
            ChoiceChip(backend.label.ifBlank { backend.id }, fields.backend == backend.id, {
                if (backend.id != fields.backend) onFields(fields.copy(backend = backend.id, model = "", effort = ""))
            })
        }
    }
    val backend = backends.firstOrNull { it.id == fields.backend }
    if (backend != null && (backend.models.isNotEmpty() || fields.model.isNotEmpty())) {
        val models = (backend.models + listOf(fields.model).filter { it.isNotEmpty() }).distinct()
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
            ChoiceChip(L10n.text("android.automationeditor.default.21b111cb"), fields.model.isEmpty(), { onFields(fields.copy(model = "")) })
            models.forEach { model ->
                ChoiceChip(model, fields.model == model, { onFields(fields.copy(model = model)) })
            }
        }
    }
    if (backend != null && (backend.efforts.isNotEmpty() || fields.effort.isNotEmpty())) {
        val efforts = (listOf("") + backend.efforts + listOf(fields.effort).filter { it.isNotEmpty() }).distinct()
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
            efforts.forEach { effort ->
                ChoiceChip(if (effort.isEmpty()) L10n.text("android.automationeditor.default.21b111cb") else effort, fields.effort == effort, { onFields(fields.copy(effort = effort)) })
            }
        }
    }
}

/// Frequency editor with the host scheduler timezone. Schedule values stay
/// exact until a picker is touched. Port of the schedule half of
/// `AutomationFieldsView` over `JobScheduleEditing`.
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ScheduleEditor(
    schedule: ScheduleFields,
    onSchedule: (ScheduleFields) -> Unit,
    timezoneCaption: String,
    enabled: Boolean,
) {
    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
        Text(L10n.text("android.automationeditor.schedule.f4830a1d"), style = TsType.body.copy(fontWeight = FontWeight.SemiBold), color = LocalTsColors.current.textPrimary)
        Text(timezoneCaption, style = TsType.caption, color = LocalTsColors.current.textSecondary)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
            ScheduleKind.entries.forEach { kind ->
                ChoiceChip(kind.label, schedule.scheduleKind == kind, { onSchedule(schedule.copy(scheduleKind = kind)) })
            }
        }
        when (schedule.scheduleKind) {
            ScheduleKind.ONCE -> {
                Text(L10n.text("android.automationeditor.runs_when_you_run_it.bab10655"), style = TsType.caption, color = LocalTsColors.current.textSecondary)
            }
            ScheduleKind.INTERVAL -> {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                    schedule.intervalMenuMinutes.forEach { minutes ->
                        ChoiceChip(
                            JobScheduleCopy.intervalPresetLabel(minutes),
                            schedule.intervalCurrentSeconds == minutes * 60L,
                            { onSchedule(schedule.copy(scheduleKind = ScheduleKind.INTERVAL, intervalMinutes = minutes.toString(), intervalTouched = true)) },
                        )
                    }
                }
                OutlinedTextField(
                    schedule.intervalMinutes,
                    { onSchedule(schedule.copy(intervalMinutes = it.filter(Char::isDigit), intervalTouched = true)) },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = enabled,
                    label = { Text(L10n.text("android.automationeditor.every_minutes.d4a198e5")) },
                )
            }
            ScheduleKind.DAILY, ScheduleKind.WEEKDAYS -> {
                if (schedule.scheduleKind == ScheduleKind.WEEKDAYS) {
                    Text(L10n.text("android.automationeditor.monday_to_friday.26a9741b"), style = TsType.caption, color = LocalTsColors.current.textSecondary)
                }
                HourMinuteFields(schedule = schedule, onSchedule = onSchedule, enabled = enabled)
            }
            ScheduleKind.WEEKLY -> {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                    JobScheduleCopy.weekdayNames.forEachIndexed { day, name ->
                        ChoiceChip(
                            JobScheduleCopy.weekdayShort[day],
                            schedule.weeklyDaySelected(day),
                            { onSchedule(schedule.copy(weekday = day, weeklyDayEdited = true)) },
                        )
                    }
                }
                Text(schedule.weeklyDayLabel, style = TsType.caption, color = LocalTsColors.current.textSecondary)
                HourMinuteFields(schedule = schedule, onSchedule = onSchedule, enabled = enabled)
            }
            ScheduleKind.CUSTOM -> {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                    JobScheduleCopy.weekdayNames.forEachIndexed { day, name ->
                        val selected = (schedule.customDays and (1 shl day)) != 0
                        ChoiceChip(
                            JobScheduleCopy.weekdayShort[day],
                            selected,
                            {
                                val bit = 1 shl day
                                onSchedule(schedule.copy(customDays = if (selected) schedule.customDays and bit.inv() else schedule.customDays or bit))
                            },
                        )
                    }
                }
                HourMinuteFields(schedule = schedule, onSchedule = onSchedule, enabled = enabled)
            }
        }
        if (schedule.validation != null && schedule.scheduleKind != ScheduleKind.ONCE) {
            Text(schedule.validation!!, style = TsType.caption, color = LocalTsColors.current.danger)
        }
    }
}

@Composable
private fun HourMinuteFields(schedule: ScheduleFields, onSchedule: (ScheduleFields) -> Unit, enabled: Boolean) {
    Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
        OutlinedTextField(
            schedule.hour.toString(),
            { onSchedule(schedule.copy(hour = it.filter(Char::isDigit).take(2).toIntOrNull() ?: 0)) },
            modifier = Modifier.weight(1f),
            enabled = enabled,
            label = { Text(L10n.text("android.automationeditor.hour.f0063b80")) },
        )
        OutlinedTextField(
            schedule.minute.toString().padStart(2, '0'),
            { onSchedule(schedule.copy(minute = it.filter(Char::isDigit).take(2).toIntOrNull() ?: 0)) },
            modifier = Modifier.weight(1f),
            enabled = enabled,
            label = { Text(L10n.text("android.automationeditor.minute.4b78665b")) },
        )
    }
}
