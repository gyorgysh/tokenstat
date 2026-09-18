// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.unit.dp
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.sp
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.cardRadiusDp
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import androidx.compose.foundation.clickable

private const val AUTO_COMMIT_NAME = "Auto commit"
private const val AUTO_COMMIT_BUDGET_SECONDS = 900

private fun autoCommitPrompt(workspaceName: String): String =
    "Commit the pending work in this git repository ($workspaceName).\n" +
        "\n" +
        "Inspect the working tree (git status and git diff). Group the changes " +
        "into one or more commits by concern. One concern per commit. A single " +
        "concern is one commit.\n" +
        "\n" +
        "Write messages that match this repository's existing style:\n" +
        "1. Follow the most recent commit subjects.\n" +
        "2. If CONTRIBUTING.md, a commitlint config, or .gitmessage exists, follow those rules.\n" +
        "3. Otherwise use Conventional Commits: lowercase type, optional scope, imperative subject, English.\n" +
        "\n" +
        "Do not push. Do not force. Do not amend. Do not change files except to commit them. " +
        "If there is nothing to commit, say so and stop.\n" +
        "\n" +
        "After you finish, list the commits you made."

/// Auto commit on Changes. Distinct from selected-file Commit: the agent
/// inspects the folder and commits. Checkboxes do not choose its files.
///
/// Only mounted when the host answers `automation.backends`; a host without
/// the automation methods keeps no card. Ports `ClientAutoCommitCard` with
/// the `AutoCommitJob` prompt, budget, and backend rules (shell stays out,
/// a backend needs models, haiku preferred).
@Composable
fun AutoCommitCard(
    model: AppViewModel,
    peer: String,
    workspace: String,
    folderName: String,
    hostLabel: String,
) {
    val scope = rememberCoroutineScope()
    var supported by remember { mutableStateOf(false) }
    var backends by remember { mutableStateOf<List<JsonObject>>(emptyList()) }
    var backendId by remember { mutableStateOf("") }
    var modelName by remember { mutableStateOf("") }
    var jobId by remember { mutableStateOf<String?>(null) }
    var pendingOp by remember { mutableStateOf<String?>(null) }
    var retryable by remember { mutableStateOf(false) }
    var running by remember { mutableStateOf(false) }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    val commitBackends = backends.filter { backend ->
        val id = backend.str("id") ?: ""
        val models = (backend["models"] as? JsonArray)?.mapNotNull { it.jsonPrimitive.contentOrNull } ?: emptyList()
        id != "sh" && models.isNotEmpty()
    }
    val backend = commitBackends.firstOrNull { it.str("id") == backendId } ?: commitBackends.firstOrNull()
    val models = backend?.let { (it["models"] as? JsonArray)?.mapNotNull { m -> m.jsonPrimitive.contentOrNull } } ?: emptyList()
    val canStart = supported && !working && backend != null && models.isNotEmpty() &&
        backend.str("id") != "sh" && !running && pendingOp == null

    suspend fun load() {
        runCatching {
            model.workspaceSection(peer, "automation.backends", buildJsonObject {})
        }.onSuccess { element ->
            backends = (element as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()
            supported = true
            if (backendId.isBlank()) {
                val first = backends.firstOrNull { it.str("id") != "sh" }
                backendId = first?.str("id") ?: ""
            }
            if (modelName.isBlank()) {
                val firstModels = (backends.firstOrNull { it.str("id") == backendId }?.get("models") as? JsonArray)
                    ?.mapNotNull { it.jsonPrimitive.contentOrNull } ?: emptyList()
                modelName = if (firstModels.contains("haiku")) "haiku" else firstModels.firstOrNull() ?: ""
            }
        }.onFailure {
            // A host without the automation methods keeps no card.
            supported = false
        }
        runCatching {
            model.workspaceSection(peer, "automation.list", buildJsonObject {})
        }.onSuccess { element ->
            val jobs = (element as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()
            val match = jobs.firstOrNull {
                (it.str("workspaceId") ?: it.str("workspace_id") ?: "") == workspace &&
                    (it.str("name") ?: "").equals(AUTO_COMMIT_NAME, ignoreCase = true)
            }
            jobId = match?.str("id")
        }
    }
    LaunchedEffect(peer, workspace) { load() }

    if (!supported) return

    suspend fun launch(job: String, opId: String): JsonObject? =
        runCatching {
            model.workspaceSection(peer, "automation.runOnce", buildJsonObject {
                put("id", job)
                put("operationId", opId)
            }) as? JsonObject
        }.getOrNull()

    fun start() {
        val chosen = backend ?: return
        if (!canStart) return
        working = true
        error = null
        scope.launch {
            val opId = java.util.UUID.randomUUID().toString()
            val existing = jobId
            val jobBody = buildJsonObject {
                if (existing != null) put("id", existing)
                put("name", AUTO_COMMIT_NAME)
                put("backend", chosen.str("id") ?: "")
                if (modelName.isNotBlank()) put("model", modelName)
                put("workspaceId", workspace)
                put("prompt", autoCommitPrompt(folderName.ifBlank { workspace }))
                put("schedule", buildJsonObject { put("kind", "once") })
                put("budgetSeconds", AUTO_COMMIT_BUDGET_SECONDS)
                put("enabled", true)
            }
            val saved: JsonObject? = runCatching {
                if (existing != null) {
                    model.workspaceSection(peer, "automation.update", buildJsonObject { put("job", jobBody) }) as? JsonObject
                } else {
                    model.workspaceSection(peer, "automation.create", buildJsonObject { put("job", jobBody) }) as? JsonObject
                }
            }.getOrNull()
            if (saved == null) {
                // A create that fails while a job exists launches the old one.
                runCatching {
                    model.workspaceSection(peer, "automation.list", buildJsonObject {})
                }.onSuccess { element ->
                    val jobs = (element as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()
                    val match = jobs.firstOrNull {
                        (it.str("workspaceId") ?: it.str("workspace_id") ?: "") == workspace &&
                            (it.str("name") ?: "").equals(AUTO_COMMIT_NAME, ignoreCase = true)
                    }
                    if (match != null) {
                        jobId = match.str("id")
                        val id = match.str("id")
                        if (id != null && !running) {
                            pendingOp = opId
                            launch(id, opId)
                        }
                        working = false
                        return@launch
                    }
                }
                error = TunnelCopy.display("The request failed.", hostLabel)
                working = false
                return@launch
            }
            jobId = saved.str("id")
            pendingOp = opId
            val outcome = saved.str("id")?.let { launch(it, opId) }
            if (outcome != null) {
                running = outcome.str("state")?.equals("running", ignoreCase = true) == true
                if (!running) pendingOp = null
            }
            working = false
        }
    }

    fun checkLaunch() {
        val opId = pendingOp ?: return
        if (working) return
        working = true
        scope.launch {
            runCatching {
                model.workspaceSection(peer, "automation.runReceipt", buildJsonObject {
                    put("operationId", opId)
                }) as? JsonObject
            }.onSuccess { outcome ->
                if (outcome != null) {
                    running = outcome.str("state")?.equals("running", ignoreCase = true) == true
                    if (!running) pendingOp = null
                    retryable = false
                    error = null
                } else {
                    retryable = true
                    error = null
                }
            }.onFailure { error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
            working = false
        }
    }

    fun retryLaunch() {
        val id = jobId ?: return
        val opId = pendingOp ?: return
        if (working) return
        working = true
        scope.launch {
            launch(id, opId)
            working = false
        }
    }

    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cardRadiusDp))
            .background(LocalTsColors.current.panel)
            .padding(Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Text(
            "Auto commit",
            style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold),
            color = LocalTsColors.current.textPrimary,
        )
        Text(
            "The chosen agent inspects this folder and commits. File checkboxes are for Review and commit.",
            style = TextStyle(fontSize = 12.sp),
            color = LocalTsColors.current.textSecondary,
        )
        Text(
            "Runs on ${hostLabel.ifBlank { "this computer" }}.",
            style = TextStyle(fontSize = 12.sp),
            color = LocalTsColors.current.textSecondary,
        )
        if (commitBackends.isEmpty()) {
            Text(
                "No agent on this computer can write a commit.",
                style = TextStyle(fontSize = 12.sp),
                color = LocalTsColors.current.textSecondary,
            )
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                BackendPicker(
                    label = "Agent",
                    options = commitBackends.map { (it.str("label") ?: it.str("id") ?: "") to (it.str("id") ?: "") },
                    selected = backendId,
                    enabled = !working && pendingOp == null,
                    onSelect = { id ->
                        backendId = id
                        val backendModels = (commitBackends.firstOrNull { it.str("id") == id }?.get("models") as? JsonArray)
                            ?.mapNotNull { it.jsonPrimitive.contentOrNull } ?: emptyList()
                        modelName = if (backendModels.contains("haiku")) "haiku" else backendModels.firstOrNull() ?: ""
                    },
                    modifier = Modifier.weight(1f),
                )
                if (models.isNotEmpty()) {
                    BackendPicker(
                        label = "Model",
                        options = models.map { it to it },
                        selected = modelName,
                        enabled = !working && pendingOp == null,
                        onSelect = { modelName = it },
                        modifier = Modifier.weight(1f),
                    )
                }
            }
        }
        if (error != null) Banner(error!!, BannerSeverity.DANGER)
        if (pendingOp != null) {
            Text(
                "This start is not confirmed yet. Check it before starting another.",
                style = TextStyle(fontSize = 12.sp),
                color = LocalTsColors.current.textSecondary,
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
            if (pendingOp != null) {
                TsSecondaryButton(label = "Check run", small = true, enabled = !working, onClick = ::checkLaunch)
                if (retryable) {
                    TsAccentButton(label = "Retry run", small = true, enabled = !working, onClick = ::retryLaunch)
                }
            } else if (running) {
                Text(
                    "Running",
                    style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.Medium),
                    color = LocalTsColors.current.accent,
                )
            } else {
                TsSecondaryButton(
                    label = if (working) "Starting…" else "Auto commit",
                    small = true,
                    enabled = canStart,
                    onClick = ::start,
                )
            }
        }
    }
}

@Composable
private fun BackendPicker(
    label: String,
    options: List<Pair<String, String>>,
    selected: String,
    enabled: Boolean,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    var expanded by remember { mutableStateOf(false) }
    val current = options.firstOrNull { it.second == selected }?.first ?: selected.ifBlank { label }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(label, style = TextStyle(fontSize = 11.sp), color = LocalTsColors.current.textSecondary)
        Text(
            current,
            style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.Medium),
            color = LocalTsColors.current.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(cardRadiusDp))
                .background(LocalTsColors.current.background)
                .clickable(enabled = enabled) { expanded = !expanded }
                .padding(Space.s),
        )
        if (expanded) {
            options.forEach { (name, id) ->
                Text(
                    name.ifBlank { id },
                    style = TextStyle(fontSize = 14.sp),
                    color = if (id == selected) LocalTsColors.current.accent else LocalTsColors.current.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onSelect(id); expanded = false }
                        .padding(horizontal = Space.s, vertical = Space.xs),
                )
            }
        }
    }
}
