// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.logic.HostContracts
import ai.tokenstat.tokenstat.ui.logic.ProjectOwner
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.*

@Composable
fun PullCreateDialog(model: AppViewModel, peer: String, workspace: String, protocol: Long?,
                     folderName: String, hostLabel: String, onDismiss: () -> Unit, onCreated: () -> Unit) {
    val android = LocalContext.current
    val uri = LocalUriHandler.current
    val scope = rememberCoroutineScope()
    val owner = remember(peer, workspace) { ProjectOwner.from(model.state.value.account, peer, workspace) }
    fun owns() = owner != null && owner == ProjectOwner.from(model.state.value.account, peer, workspace)
    val prefs = remember { android.getSharedPreferences("pull-create", 0) }
    val commit = remember(peer, workspace) { CommitUiState(peer, workspace) }
    var context by remember { mutableStateOf<JsonObject?>(null) }
    var title by remember { mutableStateOf("") }
    var body by remember { mutableStateOf("") }
    var base by remember { mutableStateOf("") }
    var isDraft by remember { mutableStateOf(true) }
    var newBranch by remember { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var loaded by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var result by remember { mutableStateOf<JsonObject?>(null) }
    var reviewing by remember { mutableStateOf(false) }
    suspend fun check() {
        if (!owns()) return
        working = true
        try {
            val prepared = model.workspaceSection(peer, "pulls.prepareCreate", buildJsonObject { put("workspaceId", workspace) }) as? JsonObject
            currentCoroutineContext().ensureActive()
            if (owns()) {
                context = prepared
                if (base.isEmpty()) base = prepared?.get("defaultBase")?.jsonPrimitive?.contentOrNull ?: ""
                error = null
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            if (owns()) { context = null; error = failure.message }
        } finally {
            working = false
        }
    }
    LaunchedEffect(owner) {
        owner?.let {
            runCatching { Json.parseToJsonElement(prefs.getString(it.key, "{}") ?: "{}") as JsonObject }.onSuccess { saved ->
                title = saved["title"]?.jsonPrimitive?.contentOrNull ?: ""
                body = saved["body"]?.jsonPrimitive?.contentOrNull ?: ""
                base = saved["base"]?.jsonPrimitive?.contentOrNull ?: ""
                isDraft = saved["draft"]?.jsonPrimitive?.booleanOrNull ?: true
            }
        }
        commit.restore(android)
        loaded = true
    }
    val supportsCreation = HostContracts.supportsPullCreation(protocol)
    LaunchedEffect(owner, loaded, supportsCreation) {
        if (loaded && supportsCreation) check()
    }
    LaunchedEffect(title, body, base, isDraft, loaded) {
        if (loaded && owns()) prefs.edit().putString(owner!!.key, buildJsonObject {
            put("title", title); put("body", body); put("base", base); put("draft", isDraft)
        }.toString()).apply()
    }
    val branch = context?.get("branch")?.jsonPrimitive?.contentOrNull ?: ""
    val published = context?.get("published")?.jsonPrimitive?.booleanOrNull == true
    val files = (context?.get("files") as? JsonArray)?.filterIsInstance<JsonObject>().orEmpty()
    Dialog(onDismissRequest = { if (!working) onDismiss() }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize()) {
            Column(Modifier.padding(20.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(L10n.text("android.pullcreate.new"), style = MaterialTheme.typography.titleLarge)
                // An unknown protocol is an old host until it says otherwise,
                // like every other feature newer than the client's first read.
                if (!supportsCreation) Text(L10n.text("android.pullcreate.update_host"))
                else if (result != null) {
                    val number = result?.get("number")?.jsonPrimitive?.content ?: ""
                    Text(if (result?.get("existing")?.jsonPrimitive?.booleanOrNull == true)
                        L10n.text("android.pullcreate.existing", number) else L10n.text("android.pullcreate.created", number))
                    TsAccentButton(label = L10n.text("android.pullcreate.open"), icon = ActionIcon.External.vector, onClick = { result?.get("url")?.jsonPrimitive?.contentOrNull?.let { uri.openUri(it) } })
                    if (result?.get("existing")?.jsonPrimitive?.booleanOrNull == true) {
                        Text(L10n.text("android.pullcreate.existing_help"), style = MaterialTheme.typography.bodySmall)
                        SelectionContainer { Column { Text(title); Text(body) } }
                    }
                } else {
                    Text(L10n.text("android.pullcreate.step_branch"), style = MaterialTheme.typography.titleMedium)
                    Text(L10n.text("android.pullcreate.branch_help", branch))
                    OutlinedTextField(newBranch, { newBranch = it }, enabled = !working, label = { Text(L10n.text("android.pullcreate.branch_name")) }, modifier = Modifier.fillMaxWidth())
                    TsSecondaryButton(label = L10n.text("android.pullcreate.make_branch"), icon = ActionIcon.Create.vector, small = true, enabled = !working && newBranch.isNotBlank(), onClick = {
                        scope.launch {
                            if (!owns()) return@launch
                            working = true
                            error = null
                            runCatching { model.workspaceSection(peer, "workspace.createBranch", buildJsonObject { put("id", workspace); put("branch", newBranch.trim()) }) as? JsonObject }
                                .onSuccess { if (it?.get("ok")?.jsonPrimitive?.booleanOrNull == true) newBranch = "" else error = it?.get("message")?.jsonPrimitive?.contentOrNull }
                                .onFailure { error = it.message }
                            working = false
                            if (error == null) check()
                        }
                    })
                    Text(L10n.text("android.pullcreate.step_commit"), style = MaterialTheme.typography.titleMedium)
                    Text(L10n.text("android.pullcreate.files_help", files.size.toString()))
                    files.forEach { file ->
                        val path = file["path"]?.jsonPrimitive?.contentOrNull ?: return@forEach
                        Row {
                            Checkbox(path in commit.selection, { commit.select(path) }, enabled = !working && commit.operationId == null)
                            Text(path, style = MaterialTheme.typography.bodySmall)
                        }
                    }
                    TsSecondaryButton(label = L10n.text("android.pullcreate.review_commit"), icon = ActionIcon.Commit.vector, small = true,
                        enabled = !working && branch.isNotEmpty() && branch != base.trim() &&
                            (commit.operationId != null || (files.isNotEmpty() && commit.selection.isNotEmpty())), onClick = {
                            scope.launch {
                                if (!owns()) return@launch
                                working = true
                                try {
                                    commit.loadStatus(model, hostLabel)
                                    commit.prepareReview(model, hostLabel, HostContracts.supportsSelectedCommit(protocol))
                                    if (owns()) reviewing = true
                                } finally { working = false }
                            }
                        })
                    Text(L10n.text("android.pullcreate.step_publish"), style = MaterialTheme.typography.titleMedium)
                    Text(if (published) L10n.text("android.pullcreate.published") else L10n.text("android.pullcreate.publish_help"))
                    if (!working && branch.isNotEmpty() && branch != base.trim()) PushButton(model, peer, workspace, folderName, hostLabel, 0, protocol) { scope.launch { check() } }
                    TsSecondaryButton(label = L10n.text("android.pullcreate.check"), icon = ActionIcon.Refresh.vector, small = true, enabled = !working, onClick = { scope.launch { check() } })
                    context?.get("problem")?.jsonPrimitive?.contentOrNull?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                    Text(L10n.text("android.pullcreate.step_describe"), style = MaterialTheme.typography.titleMedium)
                    OutlinedTextField(base, { base = it }, enabled = !working, label = { Text(L10n.text("android.pullcreate.base")) }, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(title, { title = it }, enabled = !working, label = { Text(L10n.text("android.pullcreate.title")) }, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(body, { body = it }, enabled = !working, label = { Text(L10n.text("android.pullcreate.description")) }, modifier = Modifier.fillMaxWidth(), minLines = 4)
                    Row { Checkbox(isDraft, { isDraft = it }, enabled = !working); Text(L10n.text("android.pullcreate.draft")) }
                    Text(L10n.text("android.pullcreate.final_help"), style = MaterialTheme.typography.bodySmall)
                    TsAccentButton(label = if (isDraft) L10n.text("android.pullcreate.create_draft") else L10n.text("android.pullcreate.create"),
                        icon = ActionIcon.Create.vector, enabled = !working && published && branch.isNotEmpty() && branch != base.trim() && base.isNotBlank() && title.isNotBlank(), onClick = {
                            scope.launch {
                                if (!owns()) return@launch
                                working = true
                                runCatching { model.workspaceSection(peer, "pulls.create", buildJsonObject {
                                    put("workspaceId", workspace); put("branch", branch); put("expectedHead", context?.get("head")?.jsonPrimitive?.contentOrNull ?: "")
                                    put("expectedRepository", context?.get("repository")?.jsonPrimitive?.contentOrNull ?: "")
                                    put("base", base.trim()); put("title", title.trim()); put("body", body); put("draft", isDraft)
                                }) as? JsonObject }.onSuccess {
                                    if (owns() && it != null) {
                                        result = it
                                        if (it["existing"]?.jsonPrimitive?.booleanOrNull != true) {
                                            loaded = false
                                            prefs.edit().remove(owner!!.key).apply()
                                        }
                                        onCreated()
                                    }
                                }.onFailure { error = it.message }
                                working = false
                            }
                        })
                }
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                if (working) CircularProgressIndicator()
                TextButton(onClick = onDismiss, enabled = !working) { Text(L10n.text("common.close")) }
            }
        }
    }
    if (reviewing) CommitComposerDialog(model, commit, folderName, hostLabel, HostContracts.supportsSelectedCommit(protocol),
        onDismiss = { reviewing = false; scope.launch { check() } },
        onCommitted = { scope.launch { check() } })
}
