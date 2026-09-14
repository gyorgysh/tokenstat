// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.automations

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
    val scope = rememberCoroutineScope()
    val supportsReceipts = HostContracts.supportsAutomationReceipts(protocol)
    var baseline by remember { mutableStateOf(existing) }
    var fields by remember {
        mutableStateOf(existing?.let(AutomationEditorDraft::fromJob) ?: AutomationEditorDraft.blank(workspaceID, defaultBudget))
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
                        error = "This job was deleted on the computer. Your draft is still here."
                    } else {
                        baseline = fresh
                        error = null
                    }
                }
                .onFailure { error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
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
                error = "This job was deleted on the computer. Your draft is still here."
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
                            if (!conflict) error = "The job has not changed. Your draft is ready to save again."
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
            error = TunnelCopy.display(e.message ?: "The request failed.", hostLabel)
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
        notice = "Saved ${updated.name}."
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
            error = TunnelCopy.display(message.ifBlank { "The request failed." }, hostLabel)
        } finally {
            working = false
        }
    }

    fun confirmCreation(outcome: AutomationCreationOutcome, operationID: String) {
        if (outcome.operationID != operationID) {
            error = "The computer returned a different creation. Check this job again."
            return
        }
        created = outcome.job
        pendingCreation = null
        canRetryCreate = false
        error = null
        notice = "Created ${outcome.job?.name ?: "the job"}."
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
                    .onFailure { error = "The computer did not confirm this job. Check creation before making another." }
            } else {
                canRetryCreate = true
                error = "The computer did not confirm this job. Check creation before making another."
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
                notice = "The computer has no creation receipt yet. You can retry this same job safely."
            } else {
                confirmCreation(AutomationCreationOutcome.parse(element as JsonObject), operationID)
            }
        } catch (e: Exception) {
            error = TunnelCopy.display(e.message ?: "The request failed.", hostLabel)
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
            notice = "Created ${created?.name ?: "the job"}."
            onSaved()
        } catch (e: Exception) {
            error = "The computer did not confirm this job. Check this folder's automations before creating another."
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
            notice = "Deleted."
            onSaved()
            onDismiss()
        }.onFailure {
            error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel)
        }
        working = false
    }

    LaunchedEffect(baseline?.id) { load() }

    val base = baseline
    val isCreate = base == null && created == null
    val dirty = if (base != null) !fields.matches(base) else fields.name.isNotEmpty() || fields.prompt.isNotEmpty() || fields.schedule.scheduleKind != ScheduleKind.ONCE
    val canSave = loaded && !working && !missing && !conflict && !pendingEdit && created == null && pendingCreation == null && fields.validation == null && dirty
    val canCreate = isCreate && loaded && !working && pendingCreation == null && created == null && fields.validation == null

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(Modifier.fillMaxSize().padding(Space.m).verticalScroll(rememberScrollState())) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(
                        if (isCreate) "New automation" else "Automation",
                        style = TsType.cardTitle,
                        color = LocalTsColors.current.textPrimary,
                    )
                    Text(folderName.ifBlank { hostLabel }, style = TsType.caption, color = LocalTsColors.current.textSecondary)
                }
                IconButton(onClick = onDismiss) {
                    Icon(ActionIcon.Dismiss.vector, "Close", tint = LocalTsColors.current.controlGlyph)
                }
            }
            if (error != null) {
                Banner(error!!, BannerSeverity.DANGER)
                if (base != null && !pendingEdit) {
                    TsSecondaryButton(label = "Reload job", small = true, onClick = { scope.launch { load() } })
                }
            }
            if (notice != null) {
                Text(notice!!, style = TsType.caption, color = LocalTsColors.current.textSecondary)
            }
            if (working && !loaded) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    CircularProgressIndicator()
                    Text("Loading job", color = LocalTsColors.current.textSecondary)
                }
            }
            Text("Writing", style = TsType.body.copy(fontWeight = FontWeight.SemiBold), color = LocalTsColors.current.textPrimary)
            OutlinedTextField(
                fields.name,
                { fields = fields.copy(name = it) },
                modifier = Modifier.fillMaxWidth(),
                enabled = !working && pendingCreation == null,
                label = { Text("Name") },
            )
            OutlinedTextField(
                fields.prompt,
                { fields = fields.copy(prompt = it) },
                modifier = Modifier.fillMaxWidth(),
                enabled = !working && pendingCreation == null,
                label = { Text("Prompt") },
                minLines = 6,
            )
            Text("Settings", style = TsType.body.copy(fontWeight = FontWeight.SemiBold), color = LocalTsColors.current.textPrimary)
            AutomationFolderChips(fields = fields, onFields = { fields = it }, folders = folders, lockedFolder = workspaceID)
            AutomationBackendChips(fields = fields, onFields = { fields = it }, backends = backends)
            ScheduleEditor(
                schedule = fields.schedule,
                onSchedule = { fields = fields.copy(schedule = it) },
                timezoneCaption = HostScheduleClock.timeCaption(hostLabel, timezone.ifBlank { null }),
                enabled = !working && pendingCreation == null,
            )
            Text("Time limit", style = TsType.body.copy(fontWeight = FontWeight.SemiBold), color = LocalTsColors.current.textPrimary)
            BrandToggleChip("No time limit", fields.budget.noTimeLimit, { fields = fields.copy(budget = fields.budget.copy(noTimeLimit = !fields.budget.noTimeLimit)) })
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
                    label = { Text("Minutes") },
                )
            }
            if (fields.validation != null) {
                Text(fields.validation!!, style = TsType.caption, color = LocalTsColors.current.danger)
            }
            if (conflict && base != null) {
                TsCard {
                    Column(Modifier.padding(Space.m), verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                        Text("Changed on the computer", style = TsType.body.copy(fontWeight = FontWeight.SemiBold), color = LocalTsColors.current.textPrimary)
                        Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                            TsSecondaryButton(label = "Use computer version", small = true, onClick = {
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
                            TsSecondaryButton(label = "Keep my draft", small = true, onClick = {
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
                    "This job also changed on the computer. Saving overwrites that copy.",
                    style = TsType.caption,
                    color = LocalTsColors.current.textSecondary,
                )
            }
            Spacer(Modifier.padding(top = Space.s))
            if (created != null) {
                TsAccentButton(label = "Done", onClick = onDismiss)
            } else if (pendingCreation != null) {
                Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    TsSecondaryButton(label = "Check", enabled = !working, onClick = { scope.launch { readCreation() } })
                    if (canRetryCreate) {
                        TsAccentButton(label = "Retry same job", enabled = !working, onClick = {
                            val operationID = pendingCreation ?: return@TsAccentButton
                            scope.launch { submitCreation(operationID) }
                        })
                    }
                }
            } else if (isCreate) {
                TsAccentButton(
                    label = if (working) "Creating…" else "Create job",
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
                    TsAccentButton(label = "Save job", enabled = canSave, onClick = { scope.launch { save() } })
                    TsSecondaryButton(label = "Delete", enabled = !working, onClick = { confirmingDelete = true })
                }
            }
        }
    }
    if (confirmingDelete && base != null) {
        AlertDialog(
            onDismissRequest = { confirmingDelete = false },
            title = { Text("Delete job?") },
            text = { Text("Delete \"${base.name}\"? Its run history stays on the computer.") },
            confirmButton = { Button(onClick = { scope.launch { delete() } }) { Text("Delete") } },
            dismissButton = { TextButton(onClick = { confirmingDelete = false }) { Text("Cancel") } },
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
        ChoiceChip("Uncategorized", fields.workspaceID.isEmpty(), { onFields(fields.copy(workspaceID = "")) })
        folders.forEach { folder ->
            ChoiceChip(folder.name.ifBlank { folder.id }, fields.workspaceID == folder.id, { onFields(fields.copy(workspaceID = folder.id)) })
        }
        if (fields.workspaceID.isNotEmpty() && fields.workspaceID != lockedFolder && folders.none { it.id == fields.workspaceID }) {
            ChoiceChip("Unavailable folder", true, {})
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
        BackendRef(id = fields.backend, label = "${fields.backend} · Unavailable").takeIf { fields.backend.isNotEmpty() && backends.none { it.id == fields.backend } },
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
            ChoiceChip("Default", fields.model.isEmpty(), { onFields(fields.copy(model = "")) })
            models.forEach { model ->
                ChoiceChip(model, fields.model == model, { onFields(fields.copy(model = model)) })
            }
        }
    }
    if (backend != null && (backend.efforts.isNotEmpty() || fields.effort.isNotEmpty())) {
        val efforts = (listOf("") + backend.efforts + listOf(fields.effort).filter { it.isNotEmpty() }).distinct()
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
            efforts.forEach { effort ->
                ChoiceChip(if (effort.isEmpty()) "Default" else effort, fields.effort == effort, { onFields(fields.copy(effort = effort)) })
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
        Text("Schedule", style = TsType.body.copy(fontWeight = FontWeight.SemiBold), color = LocalTsColors.current.textPrimary)
        Text(timezoneCaption, style = TsType.caption, color = LocalTsColors.current.textSecondary)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
            ScheduleKind.entries.forEach { kind ->
                ChoiceChip(kind.label, schedule.scheduleKind == kind, { onSchedule(schedule.copy(scheduleKind = kind)) })
            }
        }
        when (schedule.scheduleKind) {
            ScheduleKind.ONCE -> {
                Text("Runs when you run it.", style = TsType.caption, color = LocalTsColors.current.textSecondary)
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
                    label = { Text("Every (minutes)") },
                )
            }
            ScheduleKind.DAILY, ScheduleKind.WEEKDAYS -> {
                if (schedule.scheduleKind == ScheduleKind.WEEKDAYS) {
                    Text("Monday to Friday.", style = TsType.caption, color = LocalTsColors.current.textSecondary)
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
            label = { Text("Hour") },
        )
        OutlinedTextField(
            schedule.minute.toString().padStart(2, '0'),
            { onSchedule(schedule.copy(minute = it.filter(Char::isDigit).take(2).toIntOrNull() ?: 0)) },
            modifier = Modifier.weight(1f),
            enabled = enabled,
            label = { Text("Minute") },
        )
    }
}
