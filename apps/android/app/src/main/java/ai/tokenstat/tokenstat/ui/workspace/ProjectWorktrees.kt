// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.logic.HostContracts
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import kotlinx.serialization.json.*

@Composable
fun ProjectWorktrees(model: AppViewModel, peer: String, folder: JsonObject, onBusyChanged: (Boolean) -> Unit = {}, onOpen: (JsonObject) -> Unit) {
    val workspace = folder["id"]?.jsonPrimitive?.content.orEmpty()
    val path = folder["path"]?.jsonPrimitive?.content.orEmpty()
    var name by rememberSaveable(peer, workspace) { mutableStateOf("") }
    var prefix by rememberSaveable(peer, workspace) { mutableStateOf("work") }
    var base by rememberSaveable(peer, workspace) { mutableStateOf("HEAD") }
    var parent by rememberSaveable(peer, workspace) { mutableStateOf(path.substring(0, (path.indexOfLast { it == '/' || it == '\\' } + 1).coerceAtLeast(0))) }
    var trees by remember(peer, workspace) { mutableStateOf<List<JsonObject>>(emptyList()) }
    var available by remember(peer) { mutableStateOf(false) }
    var reading by remember(peer) { mutableStateOf(true) }
    var working by remember { mutableStateOf(false) }
    var showingFolders by rememberSaveable { mutableStateOf(false) }
    var pickingParent by rememberSaveable { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var attempt by remember { mutableStateOf(0) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(working) { onBusyChanged(working) }
    DisposableEffect(Unit) { onDispose { onBusyChanged(false) } }
    BackHandler(enabled = working) { /* Keep a submitted creation visible until its result arrives. */ }
    LaunchedEffect(peer, workspace, attempt) {
        reading = true
        error = null
        runCatching {
            val protocol = model.workspaceSection(peer, "protocol", buildJsonObject {}) as? JsonObject
            if ((HostContracts.protocolOf(protocol) ?: 0) < HostContracts.WORKTREES_MIN_PROTOCOL)
                error("Update tokenstat on this project's computer to use worktrees.")
            trees = (model.workspaceSection(peer, "workspace.worktrees", buildJsonObject { put("id", workspace) }) as JsonArray)
                .mapNotNull { it as? JsonObject }
            available = true
        }.onFailure { error = it.message ?: "Could not read worktrees." }
        reading = false
    }
    if (pickingParent) {
        FolderPickerScreen(model, peer, "Project computer", onClose = { pickingParent = false }, onAdded = {},
            onPickedPath = { parent = it; pickingParent = false })
        return
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Work on another branch without interrupting this project's chats or terminals.")
        if (reading) LinearProgressIndicator(Modifier.fillMaxWidth())
        error?.let { StickyErrorCard(it, onRetry = if (!working) ({ attempt++ }) else null) }
        if (available) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(selected = !showingFolders, onClick = { showingFolders = false }, label = { Text("New worktree") }, enabled = !working)
                FilterChip(selected = showingFolders, onClick = { showingFolders = true }, label = { Text("Working folders (${trees.size})") }, enabled = !working)
            }
            if (showingFolders) {
                trees.forEach { tree ->
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(tree["branch"]?.jsonPrimitive?.contentOrNull ?: "Detached commit", style = MaterialTheme.typography.titleSmall)
                        Text(tree["path"]?.jsonPrimitive?.content.orEmpty(), style = MaterialTheme.typography.bodySmall)
                        val missing = tree["prunable"]?.jsonPrimitive?.booleanOrNull == true
                        if (missing) Text("Folder no longer available")
                        if (!missing && tree["bare"]?.jsonPrimitive?.booleanOrNull != true) {
                            TsSecondaryButton(label = "Open project", enabled = !working, onClick = {
                                working = true
                                scope.launch {
                                    runCatching { model.workspaceSection(peer, "workspace.add", buildJsonObject { put("path", tree["path"]!!) }) as JsonObject }
                                        .onSuccess(onOpen).onFailure { error = it.message }
                                    working = false
                                }
                            })
                        }
                        HorizontalDivider()
                    }
                }
            } else {
                OutlinedTextField(name, { name = it }, label = { Text("Name") }, placeholder = { Text("improved-search") }, enabled = !working, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(prefix, { prefix = it }, label = { Text("Branch prefix (optional)") }, enabled = !working, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(base, { base = it }, label = { Text("Start from") }, enabled = !working, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(parent, { parent = it }, label = { Text("Parent folder on computer") }, enabled = !working, singleLine = true, modifier = Modifier.fillMaxWidth())
                TsSecondaryButton(label = "Choose parent folder", enabled = !working, onClick = { pickingParent = true })
                Text("Branch: ${if (prefix.isBlank()) name else "$prefix/$name"}", style = MaterialTheme.typography.bodySmall)
                TsAccentButton(label = if (working) "Creating…" else "Create worktree", enabled = !working && name.isNotBlank() && base.isNotBlank() && parent.isNotBlank(), onClick = {
                    working = true
                    error = null
                    scope.launch {
                        runCatching { model.workspaceSection(peer, "workspace.createWorktree", buildJsonObject {
                            put("id", workspace); put("parent", parent); put("folderName", name)
                            put("namespace", prefix); put("branch", name); put("from", base)
                        }) as JsonObject }.onSuccess(onOpen).onFailure { error = it.message ?: "Could not create worktree." }
                        working = false
                    }
                })
            }
        }
    }
}
