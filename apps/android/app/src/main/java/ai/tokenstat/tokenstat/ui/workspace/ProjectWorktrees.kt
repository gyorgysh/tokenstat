// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.localization.L10n

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
import androidx.compose.ui.platform.LocalContext

@Composable
fun ProjectWorktrees(model: AppViewModel, peer: String, folder: JsonObject, onBusyChanged: (Boolean) -> Unit = {}, onOpen: (JsonObject) -> Unit) {
    val workspace = folder["id"]?.jsonPrimitive?.content.orEmpty()
    val path = folder["path"]?.jsonPrimitive?.content.orEmpty()
    val context = LocalContext.current.applicationContext
    val preferences = remember(context) { context.getSharedPreferences("tokenstat.projects.v1", android.content.Context.MODE_PRIVATE) }
    var name by rememberSaveable(peer, workspace) { mutableStateOf("") }
    var prefix by rememberSaveable(peer, workspace) { mutableStateOf(preferences.getString("worktree.namespace", "work") ?: "work") }
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
                error(L10n.text("android.projectworktrees.update_tokenstat_on_this_project_s_compute.1dae246f"))
            trees = (model.workspaceSection(peer, "workspace.worktrees", buildJsonObject { put("id", workspace) }) as JsonArray)
                .mapNotNull { it as? JsonObject }
            available = true
        }.onFailure { error = it.message ?: L10n.text("android.projectworktrees.could_not_read_worktrees.1f49011b") }
        reading = false
    }
    if (pickingParent) {
        FolderPickerScreen(model, peer, L10n.text("android.projectworktrees.project_computer.e5c51d2d"), onClose = { pickingParent = false }, onAdded = {},
            onPickedPath = { parent = it; pickingParent = false })
        return
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(L10n.text("android.projectworktrees.work_on_another_branch_without_interruptin.c1a6919c"))
        if (reading) LinearProgressIndicator(Modifier.fillMaxWidth())
        error?.let { StickyErrorCard(it, onRetry = if (!working) ({ attempt++ }) else null) }
        if (available) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(selected = !showingFolders, onClick = { showingFolders = false }, label = { Text(L10n.text("android.projectworktrees.new_worktree.4f210afe")) }, enabled = !working)
                FilterChip(selected = showingFolders, onClick = { showingFolders = true }, label = { Text(L10n.text("android.projectworktrees.working_folders_0.b9b73029", "${trees.size}")) }, enabled = !working)
            }
            if (showingFolders) {
                trees.forEach { tree ->
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(tree["branch"]?.jsonPrimitive?.contentOrNull ?: L10n.text("android.projectworktrees.detached_commit.05f9a89e"), style = MaterialTheme.typography.titleSmall)
                        Text(tree["path"]?.jsonPrimitive?.content.orEmpty(), style = MaterialTheme.typography.bodySmall)
                        val missing = tree["prunable"]?.jsonPrimitive?.booleanOrNull == true
                        if (missing) Text(L10n.text("android.projectworktrees.folder_no_longer_available.c06a8a39"))
                        if (!missing && tree["bare"]?.jsonPrimitive?.booleanOrNull != true) {
                            TsSecondaryButton(label = L10n.text("android.projectworktrees.open_project.5e5eba7f"), enabled = !working, onClick = {
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
                OutlinedTextField(name, { name = it }, label = { Text(L10n.text("android.projectworktrees.name.dcd1d522")) }, placeholder = { Text(L10n.text("android.projectworktrees.improved_search.fda070d5")) }, enabled = !working, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(prefix, { prefix = it }, label = { Text(L10n.text("android.projectworktrees.branch_prefix_optional.7797f25d")) }, enabled = !working, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(base, { base = it }, label = { Text(L10n.text("android.projectworktrees.start_from.eb3f51dc")) }, enabled = !working, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(parent, { parent = it }, label = { Text(L10n.text("android.projectworktrees.parent_folder_on_computer.daa66b09")) }, enabled = !working, singleLine = true, modifier = Modifier.fillMaxWidth())
                TsSecondaryButton(label = L10n.text("android.projectworktrees.choose_parent_folder.c1b4bfea"), enabled = !working, onClick = { pickingParent = true })
                Text(L10n.text("android.projectworktrees.branch_0.1262f157", "${if (prefix.isBlank()) name else "$prefix/$name"}"), style = MaterialTheme.typography.bodySmall)
                TsAccentButton(label = if (working) L10n.text("android.projectworktrees.creating.c79ed949") else L10n.text("android.projectworktrees.create_worktree.fdedbce2"), enabled = !working && name.isNotBlank() && base.isNotBlank() && parent.isNotBlank(), onClick = {
                    working = true
                    error = null
                    scope.launch {
                        runCatching { model.workspaceSection(peer, "workspace.createWorktree", buildJsonObject {
                            put("id", workspace); put("parent", parent); put("folderName", name)
                            put("namespace", prefix); put("branch", name); put("from", base)
                        }) as JsonObject }.onSuccess {
                            preferences.edit().putString("worktree.namespace", prefix.trim()).apply()
                            onOpen(it)
                        }.onFailure { error = it.message ?: L10n.text("android.projectworktrees.could_not_create_worktree.0777d062") }
                        working = false
                    }
                })
            }
        }
    }
}
