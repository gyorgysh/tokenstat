// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workflows

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
import ai.tokenstat.tokenstat.ui.automations.AutomationJob
import ai.tokenstat.tokenstat.ui.automations.HostScheduleClock
import ai.tokenstat.tokenstat.ui.automations.ScheduleEditor
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
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/// New and Edit workflow with the phone step list. Port of
/// `WorkflowEditorView` plus `WorkflowStepListView` and
/// `WorkflowStepDetailView`.
///
/// Steps read top to bottom with explicit Then/Else/Body connections (the
/// canvas is the Mac presentation). Saves are `workflow.edit` with the
/// baseline revision on protocol 22+ hosts; a failed save is never
/// retried blindly but re-read and compared first. Creation mints one
/// `wf-` id and the check reads it back, so a lost reply can never mint
/// a second workflow. Unknown host fields ride along untouched.
@Composable
fun WorkflowEditorDialog(
    model: AppViewModel,
    peer: String,
    hostLabel: String,
    protocol: Long?,
    workspaceID: String,
    folderName: String,
    existing: WorkflowGraph?,
    backends: List<AgentBackend>,
    backendRefs: List<BackendRef>,
    automations: List<AutomationJob>,
    folders: List<FolderRef>,
    defaultBudget: Long,
    timezone: String,
    onSaved: () -> Unit,
    onDismiss: () -> Unit,
) {
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        WorkflowEditorScreen(
            model = model,
            peer = peer,
            hostLabel = hostLabel,
            protocol = protocol,
            workspaceID = workspaceID,
            folderName = folderName,
            existing = existing,
            backends = backends,
            backendRefs = backendRefs,
            automations = automations,
            folders = folders,
            defaultBudget = defaultBudget,
            timezone = timezone,
            onSaved = onSaved,
            onBack = onDismiss,
        )
    }
}

/// The workflow editor as a full page on the app background.
@Composable
fun WorkflowEditorScreen(
    model: AppViewModel,
    peer: String,
    hostLabel: String,
    protocol: Long?,
    workspaceID: String,
    folderName: String,
    existing: WorkflowGraph?,
    backends: List<AgentBackend>,
    backendRefs: List<BackendRef>,
    automations: List<AutomationJob>,
    folders: List<FolderRef>,
    defaultBudget: Long,
    timezone: String,
    onSaved: () -> Unit,
    onBack: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val supportsEdits = HostContracts.supportsWorkflowEditing(protocol)
    var baseline by remember { mutableStateOf(existing) }
    var fields by remember {
        mutableStateOf(existing?.let(WorkflowEditorDraft::fromGraph) ?: WorkflowEditorDraft.blank(workspaceID, defaultBudget))
    }
    var loaded by remember { mutableStateOf(false) }
    var working by remember { mutableStateOf(false) }
    var conflict by remember { mutableStateOf(false) }
    var missing by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var notice by remember { mutableStateOf<String?>(null) }
    var pendingID by remember { mutableStateOf<String?>(null) }
    var canRetryCreate by remember { mutableStateOf(false) }
    var created by remember { mutableStateOf<WorkflowGraph?>(null) }
    var confirmingDelete by remember { mutableStateOf(false) }
    var selectedStep by remember { mutableStateOf<String?>(null) }
    var designPrompt by remember { mutableStateOf("") }
    var designBackend by remember { mutableStateOf("") }
    var designModel by remember { mutableStateOf("") }
    var designEffort by remember { mutableStateOf("") }
    var designing by remember { mutableStateOf(false) }
    var designTranscript by remember { mutableStateOf<String?>(null) }

    suspend fun readCurrent(id: String): WorkflowGraph? {
        val element = model.workspaceSection(peer, "workflow.get", buildJsonObject { put("id", id) })
        if (element is kotlinx.serialization.json.JsonNull) return null
        return WorkflowGraph.parse(element as JsonObject)
    }

    suspend fun load() {
        working = true
        val id = baseline?.id
        if (id != null) {
            runCatching { readCurrent(id) }
                .onSuccess { fresh ->
                    if (fresh == null) {
                        missing = true
                        error = "This workflow was deleted on the computer. Your draft is still here."
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

    suspend fun applySaved(updated: WorkflowGraph) {
        baseline = updated
        fields = WorkflowEditorDraft.fromGraph(updated)
        conflict = false
        error = null
        notice = "Saved ${updated.name}."
        onSaved()
    }

    /// A failed save is never retried blindly: the host may have applied
    /// it while the reply was lost. Re-read and compare instead.
    suspend fun recoverSave(submitted: WorkflowGraph, base: WorkflowGraph, message: String) {
        val fresh = runCatching { readCurrent(base.id) }.getOrNull()
        if (fresh == null) {
            missing = true
            error = "This workflow was deleted on the computer. Your draft is still here."
            return
        }
        if (fresh.revision != base.revision && workflowContentMatches(submitted, fresh)) {
            applySaved(fresh)
            return
        }
        if (fresh.revision != base.revision) {
            conflict = true
            error = null
            return
        }
        error = message
    }

    suspend fun save() {
        val base = baseline ?: return
        working = true
        try {
            val graph = fields.makeGraph(id = base.id, lastRunAtMs = base.lastRunAtMs, lastRunID = base.lastRunID)
                .copy(revision = base.revision)
            error = null
            try {
                val element = if (supportsEdits) {
                    model.workspaceSection(peer, "workflow.edit", buildJsonObject {
                        put("workflow", graph.toJson())
                        put("expectedRevision", base.revision)
                    })
                } else {
                    model.workspaceSection(peer, "workflow.update", buildJsonObject {
                        put("workflow", graph.toJson())
                    })
                }
                applySaved(WorkflowGraph.parse(element as JsonObject))
            } catch (e: Exception) {
                recoverSave(graph, base, TunnelCopy.display(e.message ?: "The request failed.", hostLabel))
            }
        } catch (e: Exception) {
            error = e.message ?: "Check this workflow's settings."
        } finally {
            working = false
        }
    }

    suspend fun confirmCreated(graph: WorkflowGraph) {
        pendingID = null
        canRetryCreate = false
        created = graph
        baseline = graph
        fields = WorkflowEditorDraft.fromGraph(graph)
        error = null
        notice = "Created ${graph.name}."
        onSaved()
    }

    suspend fun submitCreation(graph: WorkflowGraph, id: String) {
        canRetryCreate = false
        error = null
        notice = null
        working = true
        try {
            val element = model.workspaceSection(peer, "workflow.create", buildJsonObject {
                put("workflow", graph.toJson())
            })
            confirmCreated(WorkflowGraph.parse(element as JsonObject))
        } catch (e: Exception) {
            val message = (e.message ?: "").lowercase()
            val existing = runCatching { readCurrent(id) }.getOrNull()
            if (existing != null) {
                confirmCreated(existing)
            } else if (message.contains("already exists")) {
                canRetryCreate = true
                error = "A workflow with this id is already on the computer. Check this folder before creating another."
            } else {
                canRetryCreate = true
                error = "The computer did not confirm this workflow. Check this folder's workflows before creating another."
            }
        } finally {
            working = false
        }
    }

    suspend fun checkCreated() {
        val id = pendingID ?: return
        if (working) return
        working = true
        try {
            val match = readCurrent(id)
            if (match != null) {
                confirmCreated(match)
            } else {
                canRetryCreate = true
                error = "This workflow is not in the folder yet. It may still arrive, or it may never have been created. Do not create another until you have checked."
            }
        } catch (e: Exception) {
            error = TunnelCopy.display(e.message ?: "The request failed.", hostLabel)
        } finally {
            working = false
        }
    }

    suspend fun delete() {
        val id = baseline?.id ?: return
        working = true
        runCatching {
            model.workspaceSection(peer, "workflow.remove", buildJsonObject { put("id", id) })
        }.onSuccess {
            confirmingDelete = false
            notice = "Deleted."
            onSaved()
            onBack()
        }.onFailure {
            error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel)
        }
        working = false
    }

    suspend fun design() {
        if (designPrompt.trim().isEmpty() || designing) return
        designing = true
        error = null
        try {
            val element = model.workspaceSection(peer, "workflow.design", buildJsonObject {
                put("prompt", designPrompt.trim())
                if (designBackend.isNotEmpty()) put("backend", designBackend)
                if (designModel.isNotEmpty()) put("model", designModel)
                if (designEffort.isNotEmpty()) put("effort", designEffort)
            })
            // Side-effect-free: design saves nothing and runs nothing, so a
            // lost response is safely retried with the same prompt.
            val result = WorkflowDesignResult.parse(element as JsonObject)
            fields = fields.applyDesign(result.workflow.layoutIfNeeded())
            designTranscript = result.transcript.ifBlank { null }
            notice = "Drafted from your prompt. Review the steps, then create the workflow."
        } catch (e: Exception) {
            error = TunnelCopy.display(e.message ?: "The request failed.", hostLabel)
        } finally {
            designing = false
        }
    }

    fun updateNode(id: String, transform: (WorkflowNode) -> WorkflowNode) {
        fields = fields.copy(nodes = fields.nodes.map { if (it.id == id) transform(it) else it })
    }

    LaunchedEffect(baseline?.id) { load() }

    val base = baseline
    val isCreate = base == null && created == null
    val dirty = if (base != null) !fields.matches(base) else fields.name.isNotEmpty() ||
        fields.starterID != WorkflowEditorDraft.BLANK_STARTER_ID ||
        fields.schedule.scheduleKind != ai.tokenstat.tokenstat.ui.automations.ScheduleKind.ONCE ||
        !fields.enabled
    val canSave = loaded && !working && !missing && !conflict && pendingID == null &&
        created == null && fields.validation == null && dirty && !isCreate
    val canCreate = isCreate && loaded && !working && pendingID == null && created == null && fields.validation == null
    val recipes = remember(backends) { WorkflowRecipes.recipes(backends) }

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
                    Icon(ActionIcon.Back.vector, "Back", tint = LocalTsColors.current.controlGlyph)
                }
                Column(Modifier.weight(1f)) {
                    Text(
                        if (isCreate) "New workflow" else "Workflow",
                        style = TsType.cardTitle,
                        color = LocalTsColors.current.textPrimary,
                    )
                    Text(folderName.ifBlank { hostLabel }, style = TsType.caption, color = LocalTsColors.current.textSecondary)
                }
            }
            if (!supportsEdits && !isCreate) {
                Text(
                    "Below protocol 22 every save is last-write-wins with an honest caption.",
                    style = TsType.caption,
                    color = LocalTsColors.current.textSecondary,
                )
            }
            if (error != null) {
                Banner(error!!, BannerSeverity.DANGER)
                if (base != null) {
                    TsSecondaryButton(label = "Reload workflow", small = true, onClick = { scope.launch { load() } })
                }
            }
            if (notice != null) {
                Text(notice!!, style = TsType.caption, color = LocalTsColors.current.textSecondary)
            }
            if (working && !loaded) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    CircularProgressIndicator()
                    Text("Loading workflow", color = LocalTsColors.current.textSecondary)
                }
            }
            OutlinedTextField(
                fields.name,
                { fields = fields.copy(name = it) },
                modifier = Modifier.fillMaxWidth(),
                enabled = !working && pendingID == null,
                label = { Text("Name") },
            )
            WorkflowFolderChips(fields = fields, onFields = { fields = it }, folders = folders)
            if (fields.schedule.builtSchedule.repeats) {
                BrandToggleChip("Enabled", fields.enabled, { fields = fields.copy(enabled = !fields.enabled) })
            } else {
                Text("Once workflows run from Run.", style = TsType.caption, color = LocalTsColors.current.textSecondary)
            }
            ScheduleEditor(
                schedule = fields.schedule,
                onSchedule = { fields = fields.copy(schedule = it) },
                timezoneCaption = HostScheduleClock.timeCaption(hostLabel, timezone.ifBlank { null }),
                enabled = !working && pendingID == null,
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
                    enabled = !working && pendingID == null,
                    label = { Text("Minutes") },
                )
            }
            if (isCreate) {
                StarterSection(
                    fields = fields,
                    onFields = { fields = it },
                    recipes = recipes,
                    designPrompt = designPrompt,
                    onDesignPrompt = { designPrompt = it },
                    designBackend = designBackend,
                    onDesignBackend = { designBackend = it; designModel = ""; designEffort = "" },
                    designModel = designModel,
                    onDesignModel = { designModel = it },
                    designEffort = designEffort,
                    onDesignEffort = { designEffort = it },
                    designing = designing,
                    designTranscript = designTranscript,
                    backends = backends,
                    enabled = !working && pendingID == null,
                    onDesign = { scope.launch { design() } },
                )
            }
            StepListSection(
                fields = fields,
                onAddStep = { kind ->
                    val issue = WorkflowGraphRules.additionIssue(kind, fields.nodes.size)
                    if (issue != null) {
                        error = issue
                    } else {
                        val id = WorkflowGraphRules.nextNodeID(fields.nodes)
                        val backend = if (kind == WorkflowNodeKind.AGENT) WorkflowRecipes.defaultBackend(backends).ifBlank { null } else null
                        fields = fields.copy(nodes = fields.nodes + WorkflowGraphRules.makeNode(kind, id, backend = backend))
                        selectedStep = id
                        error = null
                    }
                },
                onDeleteStep = { id ->
                    fields = fields.copy(
                        nodes = fields.nodes.filter { it.id != id },
                        edges = fields.edges.filter { it.from != id && it.to != id },
                    )
                    if (selectedStep == id) selectedStep = null
                },
                onUpdateNode = { id, transform -> updateNode(id, transform) },
                onAddEdge = { from, to, whenDo ->
                    val issue = WorkflowGraphRules.connectionIssue(from, to, fields.nodes, fields.edges)
                    if (issue != null) {
                        error = issue
                    } else {
                        val kept = fields.edges.filter { !(it.from == from && it.to == to) }
                        fields = fields.copy(edges = kept + WorkflowEdge(from, to, whenDo))
                        error = null
                    }
                },
                onRemoveEdge = { edge ->
                    fields = fields.copy(edges = fields.edges.filter { it.id != edge.id })
                },
                selectedStep = selectedStep,
                onSelectStep = { selectedStep = if (selectedStep == it) null else it },
                backends = backendRefs,
                automations = automations,
                enabled = !working && pendingID == null,
            )
            if (fields.validation != null) {
                Text(fields.validation!!, style = TsType.caption, color = LocalTsColors.current.danger)
            }
            if (conflict && base != null) {
                TsCard {
                    Column(Modifier.padding(Space.m), verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                        Text("Changed on the computer", style = TsType.body.copy(fontWeight = FontWeight.SemiBold), color = LocalTsColors.current.textPrimary)
                        Text("The computer copy moved under your draft. Saving stays off until you choose which copy continues.", style = TsType.caption, color = LocalTsColors.current.textSecondary)
                        Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                            TsSecondaryButton(label = "Use computer version", small = true, onClick = {
                                scope.launch {
                                    val fresh = readCurrent(base.id)
                                    if (fresh != null) {
                                        baseline = fresh
                                        fields = WorkflowEditorDraft.fromGraph(fresh)
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
            Spacer(Modifier.padding(top = Space.s))
            if (created != null) {
                TsAccentButton(label = "Done", onClick = onBack)
            } else if (pendingID != null) {
                Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    TsSecondaryButton(label = "Check", enabled = !working, onClick = { scope.launch { checkCreated() } })
                    if (canRetryCreate) {
                        TsAccentButton(label = "Retry same workflow", enabled = !working, onClick = {
                            val id = pendingID ?: return@TsAccentButton
                            scope.launch {
                                try {
                                    submitCreation(fields.makeGraph(id), id)
                                } catch (e: Exception) {
                                    error = e.message ?: "Check this workflow's settings."
                                }
                            }
                        })
                    }
                }
            } else if (isCreate) {
                TsAccentButton(
                    label = if (working) "Creating…" else "Create workflow",
                    enabled = canCreate,
                    onClick = {
                        val id = newWorkflowID()
                        try {
                            val graph = fields.makeGraph(id)
                            pendingID = id
                            scope.launch { submitCreation(graph, id) }
                        } catch (e: Exception) {
                            error = e.message ?: "Check this workflow's settings."
                        }
                    },
                )
            } else {
                Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    TsAccentButton(label = "Save workflow", enabled = canSave, onClick = { scope.launch { save() } })
                    TsSecondaryButton(label = "Delete", enabled = !working, onClick = { confirmingDelete = true })
                }
            }
        }
    if (confirmingDelete && base != null) {
        AlertDialog(
            onDismissRequest = { confirmingDelete = false },
            title = { Text("Delete ${base.name}?") },
            text = { Text("The graph is removed. Past runs stay on this computer.") },
            confirmButton = { Button(onClick = { scope.launch { delete() } }) { Text("Delete") } },
            dismissButton = { TextButton(onClick = { confirmingDelete = false }) { Text("Cancel") } },
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun WorkflowFolderChips(
    fields: WorkflowEditorDraft,
    onFields: (WorkflowEditorDraft) -> Unit,
    folders: List<FolderRef>,
) {
    FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
        folders.forEach { folder ->
            ChoiceChip(folder.name.ifBlank { folder.id }, fields.workspaceID == folder.id, { onFields(fields.copy(workspaceID = folder.id)) })
        }
        if (fields.workspaceID.isNotEmpty() && folders.none { it.id == fields.workspaceID }) {
            ChoiceChip("Unavailable folder", true, {})
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun StarterSection(
    fields: WorkflowEditorDraft,
    onFields: (WorkflowEditorDraft) -> Unit,
    recipes: List<WorkflowRecipe>,
    designPrompt: String,
    onDesignPrompt: (String) -> Unit,
    designBackend: String,
    onDesignBackend: (String) -> Unit,
    designModel: String,
    onDesignModel: (String) -> Unit,
    designEffort: String,
    onDesignEffort: (String) -> Unit,
    designing: Boolean,
    designTranscript: String?,
    backends: List<AgentBackend>,
    enabled: Boolean,
    onDesign: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
        Text("Start from", style = TsType.body.copy(fontWeight = FontWeight.SemiBold), color = LocalTsColors.current.textPrimary)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
            ChoiceChip("Blank", fields.isBlankStarter && fields.starterID == WorkflowEditorDraft.BLANK_STARTER_ID, { onFields(fields.applyBlank()) })
            recipes.forEach { recipe ->
                ChoiceChip(recipe.name, fields.starterID == recipe.id, { onFields(fields.applyRecipe(recipe)) })
            }
        }
        recipes.forEach { recipe ->
            if (fields.starterID == recipe.id) {
                Text(recipe.label, style = TsType.caption, color = LocalTsColors.current.textSecondary)
            }
        }
        OutlinedTextField(
            designPrompt,
            onDesignPrompt,
            modifier = Modifier.fillMaxWidth(),
            enabled = enabled && !designing,
            label = { Text("Draft from prompt") },
            minLines = 3,
        )
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
            backends.filter { it.id != "sh" }.forEach { backend ->
                ChoiceChip(backend.label.ifBlank { backend.id }, designBackend == backend.id, { onDesignBackend(backend.id) })
            }
        }
        val backend = backends.firstOrNull { it.id == designBackend }
        if (backend != null && backend.models.isNotEmpty()) {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                ChoiceChip("Default", designModel.isEmpty(), { onDesignModel("") })
                backend.models.forEach { model ->
                    ChoiceChip(model, designModel == model, { onDesignModel(model) })
                }
            }
        }
        if (backend != null && backend.efforts.isNotEmpty()) {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                ChoiceChip("Default", designEffort.isEmpty(), { onDesignEffort("") })
                backend.efforts.forEach { effort ->
                    ChoiceChip(effort, designEffort == effort, { onDesignEffort(effort) })
                }
            }
        }
        TsAccentButton(
            label = if (designing) "Designing…" else "Draft from prompt",
            small = true,
            enabled = enabled && !designing && designPrompt.trim().isNotEmpty(),
            onClick = onDesign,
        )
        if (designTranscript != null) {
            TsCard(title = "Design notes") {
                Text(designTranscript, style = TsType.caption, color = LocalTsColors.current.textSecondary, modifier = Modifier.padding(Space.m))
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun StepListSection(
    fields: WorkflowEditorDraft,
    onAddStep: (WorkflowNodeKind) -> Unit,
    onDeleteStep: (String) -> Unit,
    onUpdateNode: (String, (WorkflowNode) -> WorkflowNode) -> Unit,
    onAddEdge: (String, String, WorkflowEdgeWhen) -> Unit,
    onRemoveEdge: (WorkflowEdge) -> Unit,
    selectedStep: String?,
    onSelectStep: (String) -> Unit,
    backends: List<BackendRef>,
    automations: List<AutomationJob>,
    enabled: Boolean,
) {
    var connectingFrom by remember { mutableStateOf<String?>(null) }
    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
        Text("Steps", style = TsType.body.copy(fontWeight = FontWeight.SemiBold), color = LocalTsColors.current.textPrimary)
        fields.nodes.forEach { node ->
            val outgoing = fields.edges.filter { it.from == node.id }
            TsCard {
                Column(Modifier.padding(Space.m), verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(node.kind.label, style = TsType.caption, color = LocalTsColors.current.accent)
                            Text(node.displayTitle, style = TsType.body.copy(fontWeight = FontWeight.SemiBold), color = LocalTsColors.current.textPrimary)
                            if (node.subtitle.isNotBlank()) {
                                Text(node.subtitle, style = TsType.caption, color = LocalTsColors.current.textSecondary)
                            }
                        }
                        TextButton(onClick = { onSelectStep(node.id) }) {
                            Text(if (selectedStep == node.id) "Hide" else "Edit")
                        }
                    }
                    val issue = WorkflowGraphRules.nodeIssue(node)
                    if (issue != null) {
                        Text(issue, style = TsType.caption, color = LocalTsColors.current.danger)
                    }
                    outgoing.forEach { edge ->
                        val target = fields.nodes.firstOrNull { it.id == edge.to }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                "${WorkflowGraphRules.outgoingRole(node.kind, edge.whenDo)} → ${target?.displayTitle ?: edge.to}",
                                style = TsType.caption,
                                color = LocalTsColors.current.textSecondary,
                                modifier = Modifier.weight(1f),
                            )
                            TextButton(onClick = { onRemoveEdge(edge) }, enabled = enabled) { Text("Remove") }
                        }
                    }
                    if (connectingFrom == node.id) {
                        ConnectionPicker(
                            from = node,
                            nodes = fields.nodes,
                            outgoing = outgoing,
                            enabled = enabled,
                            onPick = { to, whenDo ->
                                onAddEdge(node.id, to, whenDo)
                                connectingFrom = null
                            },
                            onCancel = { connectingFrom = null },
                        )
                    } else {
                        TextButton(onClick = { connectingFrom = node.id }, enabled = enabled) { Text("Add connection") }
                    }
                    Text(WorkflowGraphRules.connectionCaption(node.kind), style = TsType.caption, color = LocalTsColors.current.textSecondary)
                    if (selectedStep == node.id) {
                        StepDetailFields(
                            node = node,
                            onUpdate = { transform -> onUpdateNode(node.id, transform) },
                            backends = backends,
                            automations = automations,
                            allNodes = fields.nodes,
                            enabled = enabled,
                        )
                        TextButton(onClick = { onDeleteStep(node.id) }, enabled = enabled && fields.nodes.size > 1) {
                            Text("Delete step", color = LocalTsColors.current.danger)
                        }
                    }
                }
            }
        }
        Text("Add a step", style = TsType.caption, color = LocalTsColors.current.textSecondary)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
            WorkflowGraphRules.authorableKinds.forEach { kind ->
                ChoiceChip(kind.label, false, { onAddStep(kind) })
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ConnectionPicker(
    from: WorkflowNode,
    nodes: List<WorkflowNode>,
    outgoing: List<WorkflowEdge>,
    enabled: Boolean,
    onPick: (String, WorkflowEdgeWhen) -> Unit,
    onCancel: () -> Unit,
) {
    var target by remember(from.id) { mutableStateOf<String?>(null) }
    var whenDo by remember(from.id) {
        mutableStateOf(WorkflowGraphRules.suggestedWhen(from.kind, outgoing))
    }
    Column(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
            nodes.filter { it.id != from.id }.forEach { node ->
                ChoiceChip(node.displayTitle, target == node.id, { target = node.id })
            }
        }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
            listOf(WorkflowEdgeWhen.OK, WorkflowEdgeWhen.ERROR, WorkflowEdgeWhen.ALWAYS).forEach { option ->
                ChoiceChip(WorkflowGraphRules.outgoingRole(from.kind, option), whenDo == option, { whenDo = option })
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
            TsAccentButton(
                label = "Connect",
                small = true,
                enabled = enabled && target != null,
                onClick = { onPick(target!!, whenDo) },
            )
            TsSecondaryButton(label = "Cancel", small = true, onClick = onCancel)
        }
    }
}

@Composable
private fun StepDetailFields(
    node: WorkflowNode,
    onUpdate: ((WorkflowNode) -> WorkflowNode) -> Unit,
    backends: List<BackendRef>,
    automations: List<AutomationJob>,
    allNodes: List<WorkflowNode>,
    enabled: Boolean,
) {
    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
        TitleField(node = node, onUpdate = onUpdate, enabled = enabled)
        when (node.kind) {
            WorkflowNodeKind.AGENT -> {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                    backends.filter { it.id != "sh" }.forEach { backend ->
                        ChoiceChip(backend.label.ifBlank { backend.id }, node.backend == backend.id, {
                            onUpdate { it.copy(backend = backend.id, model = null, effort = null) }
                        })
                    }
                }
                val backend = backends.firstOrNull { it.id == node.backend }
                if (backend != null && backend.models.isNotEmpty()) {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                        ChoiceChip("Default", node.model.isNullOrEmpty(), { onUpdate { it.copy(model = null) } })
                        backend.models.forEach { model ->
                            ChoiceChip(model, node.model == model, { onUpdate { it.copy(model = model) } })
                        }
                    }
                }
                if (backend != null && backend.efforts.isNotEmpty()) {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                        ChoiceChip("Default", node.effort.isNullOrEmpty(), { onUpdate { it.copy(effort = null) } })
                        backend.efforts.forEach { effort ->
                            ChoiceChip(effort, node.effort == effort, { onUpdate { it.copy(effort = effort) } })
                        }
                    }
                }
                PromptField(node = node, onUpdate = onUpdate, enabled = enabled)
            }
            WorkflowNodeKind.AUTOMATION -> {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                    automations.forEach { job ->
                        ChoiceChip(job.name, node.automationID == job.id, { onUpdate { it.copy(automationID = job.id) } })
                    }
                }
                OutlinedTextField(
                    node.promptOverride ?: "",
                    { text -> onUpdate { it.copy(promptOverride = text.ifBlank { null }) } },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = enabled,
                    label = { Text("Prompt override (optional)") },
                )
            }
            WorkflowNodeKind.HTTP -> {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                    listOf("GET", "POST", "PUT", "DELETE").forEach { method ->
                        ChoiceChip(method, (node.method ?: "GET") == method, { onUpdate { it.copy(method = method) } })
                    }
                }
                OutlinedTextField(
                    node.url ?: "",
                    { text -> onUpdate { it.copy(url = text.ifBlank { null }) } },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = enabled,
                    label = { Text("URL") },
                )
                OutlinedTextField(
                    node.headers?.entries?.joinToString("\n") { (k, v) -> "$k: $v" } ?: "",
                    { text ->
                        onUpdate {
                            it.copy(headers = text.lines().mapNotNull { line ->
                                val name = line.substringBefore(':').trim()
                                val value = line.substringAfter(':', "").trim()
                                if (name.isEmpty() || !line.contains(':')) null else name to value
                            }.toMap().ifEmpty { null })
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = enabled,
                    label = { Text("Headers (Name: value per line)") },
                    minLines = 2,
                )
                OutlinedTextField(
                    node.body ?: "",
                    { text -> onUpdate { it.copy(body = text.ifBlank { null }) } },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = enabled,
                    label = { Text("Body (optional)") },
                    minLines = 2,
                )
            }
            WorkflowNodeKind.COMMAND -> {
                OutlinedTextField(
                    node.command ?: node.prompt ?: "",
                    { text -> onUpdate { it.copy(command = text.ifBlank { null }, prompt = null) } },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = enabled,
                    label = { Text("Command") },
                    minLines = 2,
                )
            }
            WorkflowNodeKind.CONDITION -> {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                    listOf("contains" to "Contains", "equals" to "Equals", "matches" to "Matches").forEach { (value, label) ->
                        ChoiceChip(label, (node.test ?: "contains") == value, { onUpdate { it.copy(test = value) } })
                    }
                }
                OutlinedTextField(
                    node.pattern ?: "",
                    { text -> onUpdate { it.copy(pattern = text.ifBlank { null }) } },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = enabled,
                    label = { Text("Pattern") },
                )
            }
            WorkflowNodeKind.LOOP -> {
                OutlinedTextField(
                    (node.times ?: 3).toString(),
                    { text -> onUpdate { it.copy(times = text.filter(Char::isDigit).toLongOrNull()) } },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = enabled,
                    label = { Text("Passes (at most 20)") },
                )
                OutlinedTextField(
                    node.until ?: "",
                    { text -> onUpdate { it.copy(until = text.ifBlank { null }) } },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = enabled,
                    label = { Text("Until (optional)") },
                )
            }
            WorkflowNodeKind.INPUT -> {
                OutlinedTextField(
                    node.prompt ?: "",
                    { text -> onUpdate { it.copy(prompt = text.ifBlank { null }) } },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = enabled,
                    label = { Text("Starting prompt (optional)") },
                    minLines = 2,
                )
            }
            WorkflowNodeKind.GATE, WorkflowNodeKind.MCP -> Unit
        }
    }
}

@Composable
private fun TitleField(node: WorkflowNode, onUpdate: ((WorkflowNode) -> WorkflowNode) -> Unit, enabled: Boolean) {
    var title by remember(node.id) { mutableStateOf(node.title) }
    OutlinedTextField(
        title,
        {
            title = it
            onUpdate { node -> node.copy(title = title) }
        },
        modifier = Modifier.fillMaxWidth(),
        enabled = enabled,
        label = { Text("Step title") },
    )
}

@Composable
private fun PromptField(node: WorkflowNode, onUpdate: ((WorkflowNode) -> WorkflowNode) -> Unit, enabled: Boolean) {
    var prompt by remember(node.id) { mutableStateOf(node.prompt ?: "") }
    OutlinedTextField(
        prompt,
        {
            prompt = it
            onUpdate { node -> node.copy(prompt = prompt.ifBlank { null }) }
        },
        modifier = Modifier.fillMaxWidth(),
        enabled = enabled,
        label = { Text("Edit prompt") },
        minLines = 3,
    )
}
