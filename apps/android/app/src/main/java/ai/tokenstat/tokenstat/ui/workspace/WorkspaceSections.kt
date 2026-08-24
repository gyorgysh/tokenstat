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
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
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
    onOpenTerminal: (String) -> Unit,
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
        "Changes" -> ChangesSection(model, peer, workspace, data, error, loading, modifier)
        "Tasks" -> TodoSection(model, peer, workspace, data, error, loading, kindTask = true, onChanged = reload, modifier)
        "Notes" -> TodoSection(model, peer, workspace, data, error, loading, kindTask = false, onChanged = reload, modifier)
        "Workflows" -> WorkflowsSection(data, error, loading, modifier)
        "Automations" -> AutomationsSection(data, error, loading, modifier)
        "Files" -> FilesSection(data, error, loading, modifier)
        else -> EmptyState(Icons.AutoMirrored.Filled.Notes, "Nothing here", "This section has no content yet.", modifier)
    }
}

private fun methodFor(section: String): String = when (section) {
    "Sessions" -> "pty.list"
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
    onOpen: (String) -> Unit,
    onLoad: () -> Unit,
    modifier: Modifier,
) {
    val sessions = asObjects(data)
    LazyColumn(modifier, verticalArrangement = Arrangement.spacedBy(Space.s)) {
        if (error != null) item { SectionError(error) }
        if (!loading && sessions.isEmpty()) {
            item {
                EmptyState(
                    Icons.Default.Terminal,
                    "No live sessions",
                    "Terminals running on the host appear here. Open one to watch or type.",
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
                EmptyState(Icons.Default.Difference, "A clean tree", "No uncommitted changes on this folder right now.")
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
    data: JsonElement?,
    error: String?,
    loading: Boolean,
    modifier: Modifier,
) {
    val workflows = asObjects(data)
    LazyColumn(modifier, verticalArrangement = Arrangement.spacedBy(Space.s)) {
        if (error != null) item { SectionError(error) }
        if (!loading && workflows.isEmpty()) {
            item { EmptyState(Icons.Default.AccountTree, "No workflows yet", "Workflows built on the Mac appear here, read-only.") }
        }
        itemsIndexed(workflows) { _, wf ->
            WorkflowCard(wf)
        }
    }
}

/// A workflow as a picture: named step capsules joined left-to-right, the
/// compact reading of `MiniGraph`/`WorkflowStepStrip` in a phone column.
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun WorkflowCard(wf: JsonObject) {
    val colors = LocalTsColors.current
    val steps = (wf["steps"] as? JsonArray)?.filterIsInstance<JsonObject>().orEmpty()
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
    data: JsonElement?,
    error: String?,
    loading: Boolean,
    modifier: Modifier,
) {
    val automations = asObjects(data)
    LazyColumn(modifier, verticalArrangement = Arrangement.spacedBy(Space.s)) {
        if (error != null) item { SectionError(error) }
        if (!loading && automations.isEmpty()) {
            item { EmptyState(Icons.Default.Bolt, "No automations yet", "Scheduled runs configured on the host appear here.") }
        }
        itemsIndexed(automations) { _, automation ->
            val colors = LocalTsColors.current
            val enabled = automation.bol("enabled")
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
                            .padding(horizontal = Space.s, vertical = 2.dp),
                    ) {
                        Text(
                            if (enabled) "ON" else "OFF",
                            style = TextStyle(fontSize = 9.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.Bold),
                            color = if (enabled) colors.accent else colors.controlGlyph,
                        )
                    }
                }
                automation.str("cadence")?.let {
                    Text(it, style = TextStyle(fontSize = 12.sp), color = colors.textSecondary)
                }
            }
        }
    }
}

@Composable
private fun FilesSection(
    data: JsonElement?,
    error: String?,
    loading: Boolean,
    modifier: Modifier,
) {
    val entries = asObjects(data)
    LazyColumn(modifier, verticalArrangement = Arrangement.spacedBy(Space.xs)) {
        if (error != null) item { SectionError(error) }
        if (!loading && entries.isEmpty()) {
            item { EmptyState(Icons.Default.FolderOpen, "Empty folder", "This folder has nothing registered on the host.") }
        }
        itemsIndexed(entries) { _, entry ->
            Column {
                Row(
                    Modifier.fillMaxWidth().padding(vertical = Space.xs),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Space.s),
                ) {
                    Icon(Icons.Default.FolderOpen, null, tint = LocalTsColors.current.accent)
                    Text(
                        entry.str("name") ?: entry.str("path") ?: "",
                        style = TsType.mono(12),
                        color = LocalTsColors.current.textPrimary,
                    )
                }
                HorizontalDivider(color = LocalTsColors.current.border)
            }
        }
    }
}
