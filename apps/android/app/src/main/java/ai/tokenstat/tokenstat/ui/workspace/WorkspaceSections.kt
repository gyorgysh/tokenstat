// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.InsertDriveFile
import androidx.compose.material.icons.automirrored.filled.Notes
import androidx.compose.material.icons.filled.AccountTree
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.filled.Difference
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.filled.Unarchive
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.EmptyState
import ai.tokenstat.tokenstat.ui.components.SectionLabel
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.components.cardRadiusDp
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import ai.tokenstat.tokenstat.ui.marks.CadenceGlyph
import ai.tokenstat.tokenstat.ui.marks.EmptyArt
import ai.tokenstat.tokenstat.ui.marks.EmptyArtKind
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import androidx.compose.material.icons.filled.Language
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

private fun JsonObject.str(key: String): String? =
    this[key]?.takeUnless { it is JsonNull }?.jsonPrimitive?.contentOrNull

private fun JsonObject.bol(key: String): Boolean = this[key]?.jsonPrimitive?.booleanOrNull == true

private fun asObjects(element: JsonElement?): List<JsonObject> =
    (element as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()/// One workspace section, rendered as its own surface instead of a raw JSON
/// dump. Each section reaches the real remote method over the tunnel; the
/// renderers mirror their Apple counterparts' content and colour rules.
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun WorkspaceSection(
    model: AppViewModel,
    peer: String,
    workspace: String,
    hostLabel: String,
    section: String,
    modifier: Modifier = Modifier,
    protocol: Long? = null,
    onOpenTerminal: (String?) -> Unit,
    onOpenBrowser: (String, Int) -> Unit = { _, _ -> },
) {
    val scope = rememberCoroutineScope()
    var data by remember(section) { mutableStateOf<JsonElement?>(null) }
    var error by remember(section) { mutableStateOf<String?>(null) }
    var loading by remember(section) { mutableStateOf(true) }

    suspend fun load() {
        loading = true
        val params = buildJsonObject {
            when (section) {
                "Sessions" -> put("includeRemote", false)
                "Files" -> { put("id", workspace); put("path", "") }
                "Changes" -> put("id", workspace)
                "Tasks", "Notes" -> put("includeArchived", true)
                else -> put("workspaceId", workspace)
            }
        }
        runCatching { model.workspaceSection(peer, methodFor(section), params) }
            .onSuccess { data = it; error = null }
            .onFailure { error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
        loading = false
    }
    LaunchedEffect(section) { load() }

    val reload: () -> Unit = { scope.launch { load() } }
    when (section) {
        "Sessions" -> SessionsSection(data, error, loading, onOpenTerminal, reload, modifier)
        "Chat" -> ChatSection(model, peer, workspace, protocol = protocol, modifier)
        "Pulls" -> PullsSection(model, peer, workspace, protocol = protocol, modifier)
        "Changes" -> ChangesSection(model, peer, workspace, data, error, loading, modifier)
        "Tasks" -> TodoSection(model, peer, workspace, data, error, loading, kindTask = true, onChanged = reload, modifier)
        "Notes" -> TodoSection(model, peer, workspace, data, error, loading, kindTask = false, onChanged = reload, modifier)
        "Workflows" -> WorkflowsSection(model, peer, workspace, data, error, loading, reload, modifier)
        "Automations" -> AutomationsSection(model, peer, data, error, loading, reload, modifier)
        "Files" -> FilesSection(model, peer, workspace, modifier)
        "Browser" -> BrowserSection(model, peer, onOpenBrowser, modifier)
        else -> EmptyState(Icons.AutoMirrored.Filled.Notes, "Nothing here", "This section has no content yet.", modifier)
    }
}

private fun methodFor(section: String): String = when (section) {
    "Sessions" -> "pty.list"
    "Chat" -> "chat.list"
    "Pulls" -> "pulls.list"
    "Changes" -> "workspace.status"
    "Tasks", "Notes" -> "todo.list"
    "Workflows" -> "workflow.list"
    "Automations" -> "automation.list"
    "Files" -> "workspace.tree"
    else -> "host.stats"
}

@Composable
private fun SectionError(error: String?) {
    if (error != null) Banner(error, BannerSeverity.DANGER)
}

@Composable
private fun SessionsSection(
    data: JsonElement?,
    error: String?,
    loading: Boolean,
    onOpen: (String?) -> Unit,
    onLoad: () -> Unit,
    modifier: Modifier,
) {
    val sessions = asObjects(data)
    LazyColumn(modifier, verticalArrangement = Arrangement.spacedBy(Space.s)) {
        item {
            TsAccentButton(label = "New shell", small = true, onClick = { onOpen(null) })
        }
        if (error != null) item { SectionError(error) }
        if (!loading && sessions.isEmpty()) {
            item {
                EmptyState(
                    Icons.Default.Terminal,
                    "No live sessions",
                    "Terminals running on the host appear here. Open one to watch or type.",
                    art = { EmptyArt(EmptyArtKind.Sessions) },
                )
            }
        }
        itemsIndexed(sessions) { _, session ->
            val id = session.str("id") ?: return@itemsIndexed
            Row(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(cardRadiusDp))
                    .background(LocalTsColors.current.panel)
                    .clickable(indication = null, interactionSource = remember { MutableInteractionSource() }) { onOpen(id) }
                    .padding(Space.m),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Space.s),
            ) {
                Icon(Icons.Default.Terminal, null, tint = LocalTsColors.current.accent)
                Column(Modifier.weight(1f)) {
                    Text(session.str("command") ?: "shell", style = TsType.mono(13), color = LocalTsColors.current.textPrimary)
                    Text(
                        listOfNotNull(session.str("status"), session.str("title")).joinToString(" · ").ifBlank { id },
                        style = TextStyle(fontSize = 11.sp),
                        color = LocalTsColors.current.textTertiary,
                        maxLines = 1,
                    )
                }
            }
        }
    }
}

private fun index(o: JsonObject): Int = o.hashCode()

/// Read-only diff rendering: added/removed line rows in the Theme diff pair —
/// green and red because a diff is the one place those two colours are not a
/// traffic light (`ClientDiffView.swift`).
@Composable
fun DiffView(patch: String, modifier: Modifier = Modifier) {
    val colors = LocalTsColors.current
    Column(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cardRadiusDp))
            .background(colors.background),
    ) {
        patch.lines().forEachIndexed { index, line ->
            val bg = when {
                line.startsWith("+") && !line.startsWith("+++") -> colors.diffAdded.copy(alpha = 0.14f)
                line.startsWith("-") && !line.startsWith("---") -> colors.diffRemoved.copy(alpha = 0.14f)
                line.startsWith("@@") -> colors.accentSoft
                else -> Color.Transparent
            }
            val fg = when {
                line.startsWith("+") && !line.startsWith("+++") -> colors.diffAdded
                line.startsWith("-") && !line.startsWith("---") -> colors.diffRemoved
                else -> colors.textPrimary
            }
            Text(
                line.ifBlank { " " },
                style = TsType.mono(11),
                color = fg,
                modifier = Modifier
                    .fillMaxWidth()
                    .background(bg)
                    .padding(horizontal = Space.s, vertical = 1.dp),
                maxLines = 8,
            )
        }
    }
}

@Composable
private fun ChangesSection(
    model: AppViewModel,
    peer: String,
    workspace: String,
    data: JsonElement?,
    error: String?,
    loading: Boolean,
    modifier: Modifier,
) {
    val files = asObjects(data).ifEmpty { asObjects((data as? JsonObject)?.get("files")) }
    var openPath by remember { mutableStateOf<String?>(null) }
    var openPatch by remember { mutableStateOf("") }
    LaunchedEffect(openPath) {
        val path = openPath ?: return@LaunchedEffect
        runCatching {
            model.workspaceSection(peer, "workspace.diff", buildJsonObject {
                put("id", workspace); put("path", path)
            })
        }.onSuccess { element ->
            val obj = element as? JsonObject
            openPatch = obj?.get("patch")?.jsonPrimitive?.contentOrNull
                ?: obj?.get("diff")?.jsonPrimitive?.contentOrNull
                ?: element.toString()
        }.onFailure { openPatch = it.message ?: "" }
    }
    LazyColumn(modifier, verticalArrangement = Arrangement.spacedBy(Space.s)) {
        if (error != null) item { SectionError(error) }
        if (!loading && files.isEmpty()) {
            item {
                EmptyState(
                    Icons.Default.Difference,
                    "A clean tree",
                    "No uncommitted changes on this folder right now.",
                    art = { EmptyArt(EmptyArtKind.Changes) },
                )
            }
        }
        itemsIndexed(files) { _, file ->
            val path = file.str("path") ?: file.str("name") ?: return@itemsIndexed
            val status = file.str("status") ?: file.str("index") ?: ""
            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(cardRadiusDp))
                    .background(LocalTsColors.current.panel)
                    .padding(Space.m),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        path,
                        style = TsType.mono(12),
                        color = LocalTsColors.current.textPrimary,
                        modifier = Modifier.weight(1f),
                        maxLines = 2,
                    )
                    if (status.isNotBlank()) Text(
                        status.uppercase(),
                        style = TextStyle(fontSize = 10.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.Bold),
                        color = LocalTsColors.current.accent,
                    )
                }
                TsSecondaryButton(
                    label = "View diff",
                    small = true,
                    modifier = Modifier.padding(top = Space.xs),
                    onClick = { openPath = path },
                )
            }
        }
    }
    if (openPath != null) {
        AlertDialog(
            onDismissRequest = { openPath = null },
            title = { Text(openPath.orEmpty(), style = TsType.mono(13)) },
            text = {
                LazyColumn(Modifier.height(420.dp)) {
                    item {
                        if (openPatch.isBlank()) Text("Loading…", color = LocalTsColors.current.textSecondary)
                        else DiffView(openPatch)
                    }
                }
            },
            confirmButton = { TextButton(onClick = { openPath = null }) { Text("Close") } },
        )
    }
}

@Composable
private fun TodoSection(
    model: AppViewModel,
    peer: String,
    workspace: String,
    data: JsonElement?,
    error: String?,
    loading: Boolean,
    kindTask: Boolean,
    onChanged: () -> Unit,
    modifier: Modifier,
) {
    val scope = rememberCoroutineScope()
    val cards = asObjects(data).filter { (it.str("kind") ?: "task") == if (kindTask) "task" else "note" }
    var composer by remember { mutableStateOf(false) }

    LazyColumn(modifier, verticalArrangement = Arrangement.spacedBy(Space.s)) {
        if (error != null) item { SectionError(error) }
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                SectionLabel(if (kindTask) "Tasks" else "Notes", cards.size, Modifier.weight(1f))
                TsAccentButton(
                    label = if (kindTask) "Add task" else "Add note",
                    small = true,
                    onClick = { composer = true },
                )
            }
        }
        if (!loading && cards.isEmpty()) {
            item {
                EmptyState(
                    if (kindTask) Icons.Default.Checklist else Icons.AutoMirrored.Filled.Notes,
                    if (kindTask) "No tasks yet" else "No notes yet",
                    if (kindTask) {
                        "Cards captured here land on the Mac's board for this folder."
                    } else {
                        "A note is text kept beside the folder it belongs to."
                    },
                    art = { EmptyArt(if (kindTask) EmptyArtKind.Tasks else EmptyArtKind.Notes) },
                )
            }
        }
        itemsIndexed(cards) { _, card ->
            val id = card.str("id") ?: return@itemsIndexed
            val archived = (card.str("column") ?: "") == "archived"
            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(cardRadiusDp))
                    .background(LocalTsColors.current.panel)
                    .padding(Space.m),
                verticalArrangement = Arrangement.spacedBy(Space.xs),
            ) {
                Text(
                    card.str("title") ?: "",
                    style = TextStyle(fontSize = 14.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.Medium),
                    color = LocalTsColors.current.textPrimary,
                )
                card.str("notes")?.takeIf { it.isNotBlank() }?.let {
                    Text(it, style = TextStyle(fontSize = 12.sp), color = LocalTsColors.current.textSecondary, maxLines = 4)
                }
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    Text(
                        (card.str("column") ?: "backlog").replaceFirstChar(Char::uppercase),
                        style = TextStyle(fontSize = 11.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold),
                        color = LocalTsColors.current.accent,
                    )
                    Spacer(Modifier.weight(1f))
                    IconButton(onClick = {
                        scope.launch {
                            runCatching {
                                model.workspaceSection(peer, "todo.update", buildJsonObject {
                                    put("id", id)
                                    put("column", if (archived) "backlog" else "archived")
                                })
                            }
                            onChanged()
                        }
                    }) {
                        Icon(if (archived) Icons.Default.Unarchive else Icons.Default.Archive, if (archived) "Restore" else "Archive")
                    }
                }
            }
        }
    }
    if (composer) {
        ComposerDialog(
            title = if (kindTask) "New task" else "New note",
            onDismiss = { composer = false },
            onSave = { text ->
                composer = false
                scope.launch {
                    runCatching {
                        model.workspaceSection(peer, "todo.create", buildJsonObject {
                            put("title", text)
                            put("kind", if (kindTask) "task" else "note")
                            put("notes", "")
                            put("column", "backlog")
                            put("backend", "")
                            put("workspaceId", workspace)
                            // A note is never delegated, so its budget is moot;
                            // a task gets the Mac's default three hours.
                            put("budgetSeconds", if (kindTask) 180 * 60 else 0)
                        })
                    }
                    onChanged()
                }
            },
        )
    }
}

@Composable
private fun ComposerDialog(title: String, onDismiss: () -> Unit, onSave: (String) -> Unit) {
    var text by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { OutlinedTextField(text, { text = it }, minLines = 3, modifier = Modifier.fillMaxWidth()) },
        confirmButton = { Button(enabled = text.isNotBlank(), onClick = { onSave(text.trim()) }) { Text("Save") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun WorkflowsSection(
    model: AppViewModel,
    peer: String,
    workspace: String,
    data: JsonElement?,
    error: String?,
    loading: Boolean,
    onChanged: () -> Unit,
    modifier: Modifier,
) {
    val scope = rememberCoroutineScope()
    val workflows = asObjects(data)
    var transcript by remember { mutableStateOf<String?>(null) }
    LazyColumn(modifier, verticalArrangement = Arrangement.spacedBy(Space.s)) {
        if (error != null) item { SectionError(error) }
        if (!loading && workflows.isEmpty()) {
            item {
                EmptyState(
                    Icons.Default.AccountTree,
                    "No workflows yet",
                    "Workflows built on the Mac appear here. Run one from this phone.",
                    art = { EmptyArt(EmptyArtKind.Workflows) },
                )
            }
        }
        itemsIndexed(workflows) { _, wf ->
            WorkflowCard(
                wf = wf,
                onRun = {
                    val id = wf.str("id") ?: return@WorkflowCard
                    scope.launch {
                        runCatching {
                            model.workspaceSection(peer, "workflow.run", buildJsonObject {
                                put("id", id)
                                put("input", "")
                                put("workspaceId", workspace)
                            })
                        }
                        onChanged()
                    }
                },
                onKill = { runId ->
                    scope.launch {
                        runCatching {
                            model.workspaceSection(peer, "workflow.kill", buildJsonObject { put("id", runId) })
                        }
                        onChanged()
                    }
                },
                onTranscript = { runId, nodeId ->
                    scope.launch {
                        runCatching {
                            val chunk = model.workspaceSection(peer, "workflow.transcript", buildJsonObject {
                                put("id", runId)
                                put("nodeId", nodeId)
                                put("offset", 0)
                            }) as? JsonObject
                            transcript = chunk?.str("text") ?: chunk?.str("content") ?: chunk.toString()
                        }.onFailure { transcript = it.message }
                    }
                },
            )
        }
    }
    if (transcript != null) {
        AlertDialog(
            onDismissRequest = { transcript = null },
            title = { Text("Transcript") },
            text = { Text(transcript.orEmpty(), style = TsType.mono(11)) },
            confirmButton = { TextButton(onClick = { transcript = null }) { Text("Close") } },
        )
    }
}

/// A workflow as a picture: named step capsules joined left-to-right, the
/// compact reading of `MiniGraph`/`WorkflowStepStrip` in a phone column.
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun WorkflowCard(
    wf: JsonObject,
    onRun: () -> Unit,
    onKill: (String) -> Unit,
    onTranscript: (String, String) -> Unit,
) {
    val colors = LocalTsColors.current
    val steps = (wf["steps"] as? JsonArray)?.filterIsInstance<JsonObject>().orEmpty()
    val liveRun = wf.str("runId") ?: wf.str("liveRunId")
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cardRadiusDp))
            .background(colors.panel)
            .padding(Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Text(
            wf.str("name") ?: wf.str("title") ?: "Workflow",
            style = TextStyle(fontSize = 14.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold),
            color = colors.textPrimary,
        )
        if (steps.isNotEmpty()) {
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(Space.xs),
                verticalArrangement = Arrangement.spacedBy(Space.xs),
            ) {
                steps.forEachIndexed { index, step ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        StepCapsule(step.str("label") ?: step.str("name") ?: "step")
                        if (index < steps.lastIndex) {
                            Text("→", color = colors.textTertiary, modifier = Modifier.padding(horizontal = 2.dp))
                        }
                    }
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
            TsAccentButton(label = "Run", small = true, onClick = onRun)
            if (liveRun != null) {
                TsSecondaryButton(label = "Stop", small = true, onClick = { onKill(liveRun) })
                steps.firstOrNull()?.str("id")?.let { node ->
                    TsSecondaryButton(label = "Transcript", small = true, onClick = { onTranscript(liveRun, node) })
                }
            }
        }
    }
}

@Composable
private fun StepCapsule(label: String) {
    Box(
        Modifier
            .clip(RoundedCornerShape(50))
            .background(LocalTsColors.current.accentSoft)
            .padding(horizontal = Space.s, vertical = 2.dp),
    ) {
        Text(
            label,
            style = TextStyle(fontSize = 11.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.Medium),
            color = LocalTsColors.current.accent,
            maxLines = 1,
        )
    }
}

@Composable
private fun AutomationsSection(
    model: AppViewModel,
    peer: String,
    data: JsonElement?,
    error: String?,
    loading: Boolean,
    onChanged: () -> Unit,
    modifier: Modifier,
) {
    val scope = rememberCoroutineScope()
    val automations = asObjects(data)
    LazyColumn(modifier, verticalArrangement = Arrangement.spacedBy(Space.s)) {
        if (error != null) item { SectionError(error) }
        if (!loading && automations.isEmpty()) {
            item {
                EmptyState(
                    Icons.Default.Bolt,
                    "No automations yet",
                    "Scheduled runs configured on the host appear here.",
                    art = { EmptyArt(EmptyArtKind.Automations) },
                )
            }
        }
        itemsIndexed(automations) { _, automation ->
            val colors = LocalTsColors.current
            val enabled = automation.bol("enabled")
            val id = automation.str("id") ?: return@itemsIndexed
            val cadence = automation.str("cadence").orEmpty()
            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(cardRadiusDp))
                    .background(colors.panel)
                    .padding(Space.m),
                verticalArrangement = Arrangement.spacedBy(Space.xs),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        automation.str("label") ?: automation.str("name") ?: "Automation",
                        style = TextStyle(fontSize = 14.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold),
                        color = colors.textPrimary,
                        modifier = Modifier.weight(1f),
                    )
                    Box(
                        Modifier
                            .clip(RoundedCornerShape(50))
                            .background(if (enabled) colors.accentSoft else colors.controlSeat)
                            .padding(horizontal = Space.s, vertical = 2.dp)
                            .clickable {
                                scope.launch {
                                    runCatching {
                                        model.workspaceSection(
                                            peer,
                                            if (enabled) "automation.disable" else "automation.enable",
                                            buildJsonObject { put("id", id) },
                                        )
                                    }
                                    onChanged()
                                }
                            },
                    ) {
                        Text(
                            if (enabled) "ON" else "OFF",
                            style = TextStyle(fontSize = 9.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.Bold),
                            color = if (enabled) colors.accent else colors.controlGlyph,
                        )
                    }
                }
                if (cadence.isNotBlank()) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                        CadenceGlyph(cadence)
                        Text(cadence, style = TextStyle(fontSize = 12.sp), color = colors.textSecondary)
                    }
                }
                TsAccentButton(
                    label = "Run",
                    small = true,
                    onClick = {
                        scope.launch {
                            runCatching {
                                model.workspaceSection(peer, "automation.run", buildJsonObject { put("id", id) })
                            }
                            onChanged()
                        }
                    },
                )
            }
        }
    }
}

@Composable
private fun FilesSection(
    model: AppViewModel,
    peer: String,
    workspace: String,
    modifier: Modifier,
) {
    val scope = rememberCoroutineScope()
    var path by remember { mutableStateOf("") }
    var entries by remember { mutableStateOf<List<JsonObject>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    var loading by remember { mutableStateOf(true) }
    var editorPath by remember { mutableStateOf<String?>(null) }
    var editorBody by remember { mutableStateOf("") }

    suspend fun load(at: String) {
        loading = true
        runCatching {
            model.workspaceSection(peer, "workspace.tree", buildJsonObject {
                put("id", workspace); put("path", at)
            })
        }.onSuccess {
            entries = asObjects(it).ifEmpty { asObjects((it as? JsonObject)?.get("entries")) }
            error = null
        }.onFailure { error = it.message }
        loading = false
    }
    LaunchedEffect(path) { load(path) }

    LazyColumn(modifier, verticalArrangement = Arrangement.spacedBy(Space.xs)) {
        if (path.isNotEmpty()) {
            item {
                TsSecondaryButton(label = "Up", small = true, onClick = {
                    path = path.trimEnd('/').substringBeforeLast('/', "")
                })
            }
        }
        if (error != null) item { SectionError(error) }
        if (!loading && entries.isEmpty()) {
            item {
                EmptyState(
                    Icons.Default.FolderOpen,
                    "Empty folder",
                    "This folder has nothing registered on the host.",
                    art = { EmptyArt(EmptyArtKind.Files) },
                )
            }
        }
        itemsIndexed(entries) { _, entry ->
            val name = entry.str("name") ?: entry.str("path") ?: return@itemsIndexed
            val child = entry.str("path") ?: listOf(path, name).filter { it.isNotBlank() }.joinToString("/")
            val dir = entry.bol("dir") || entry.bol("isDir") || entry.str("kind") == "dir" || entry.str("type") == "dir"
            Column {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable {
                            if (dir) {
                                path = child
                            } else {
                                scope.launch {
                                    runCatching {
                                        val read = model.workspaceSection(peer, "workspace.read", buildJsonObject {
                                            put("id", workspace); put("path", child)
                                        }) as? JsonObject
                                        editorPath = child
                                        editorBody = read?.str("content") ?: ""
                                    }.onFailure { error = it.message }
                                }
                            }
                        }
                        .padding(vertical = Space.xs),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Space.s),
                ) {
                    Icon(
                        if (dir) Icons.Default.FolderOpen else Icons.AutoMirrored.Filled.InsertDriveFile,
                        null,
                        tint = LocalTsColors.current.accent,
                    )
                    Text(name, style = TsType.mono(12), color = LocalTsColors.current.textPrimary)
                }
                HorizontalDivider(color = LocalTsColors.current.border)
            }
        }
    }
    val editing = editorPath
    if (editing != null) {
        AlertDialog(
            onDismissRequest = { editorPath = null },
            title = { Text(editing, style = TsType.mono(12)) },
            text = {
                OutlinedTextField(
                    editorBody,
                    { editorBody = it },
                    minLines = 8,
                    modifier = Modifier.fillMaxWidth(),
                )
            },
            confirmButton = {
                TsAccentButton(
                    label = "Save",
                    small = true,
                    onClick = {
                        scope.launch {
                            runCatching {
                                model.workspaceSection(peer, "workspace.write", buildJsonObject {
                                    put("id", workspace)
                                    put("path", editing)
                                    put("content", editorBody)
                                })
                            }
                            editorPath = null
                        }
                    },
                )
            },
            dismissButton = { TextButton(onClick = { editorPath = null }) { Text("Close") } },
        )
    }
}

@Composable
private fun BrowserSection(
    model: AppViewModel,
    peer: String,
    onOpen: (String, Int) -> Unit,
    modifier: Modifier,
) {
    val scope = rememberCoroutineScope()
    var portText by remember { mutableStateOf("3000") }
    var error by remember { mutableStateOf<String?>(null) }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(Space.s)) {
        Text("Open a port on that computer in this phone's browser.", color = LocalTsColors.current.textSecondary)
        OutlinedTextField(
            portText,
            { portText = it.filter(Char::isDigit).take(5) },
            label = { Text("Port") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
            leadingIcon = { Icon(Icons.Default.Language, null) },
        )
        error?.let { SectionError(it) }
        TsAccentButton(
            label = "Open",
            onClick = {
                val port = portText.toIntOrNull() ?: return@TsAccentButton
                scope.launch {
                    runCatching {
                        val opened = model.core(
                            "proxy.listen",
                            buildJsonObject {
                                put("peer", peer)
                                put("host", "127.0.0.1")
                                put("port", port)
                            },
                        ) as JsonObject
                        val url = opened.str("url") ?: "http://127.0.0.1:$port/"
                        onOpen(url, port)
                    }.onFailure { error = it.message }
                }
            },
        )
    }
}
