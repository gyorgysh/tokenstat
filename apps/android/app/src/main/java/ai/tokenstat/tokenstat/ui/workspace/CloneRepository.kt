// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
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
import androidx.compose.ui.unit.dp
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.setup.SetupFailure
import ai.tokenstat.tokenstat.ui.terminal.TerminalScreen
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/// Getting a repository onto a machine that has none. Ported from
/// `ClientCloneRepository.swift`.
///
/// A folder has to exist before it can be registered, and on a fresh server
/// nothing does. The clone runs in a real terminal rather than behind a
/// spinner: one that asks for a passphrase or an unknown host key can be
/// answered, and one that hangs looks like a terminal that stopped moving.
/// Nothing is ever removed, including a clone that failed halfway.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CloneRepositoryScreen(
    model: AppViewModel,
    peer: String,
    hostLabel: String,
    onClose: () -> Unit,
    onCloned: (folderId: String) -> Unit,
) {
    var url by remember { mutableStateOf("") }
    var parent by remember { mutableStateOf<String?>(null) }
    var name by remember { mutableStateOf("") }
    var sessionId by remember { mutableStateOf<String?>(null) }
    var status by remember { mutableStateOf<CloneStatus?>(null) }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var picking by remember { mutableStateOf(false) }
    var statusAttempt by remember { mutableStateOf(0) }
    val scope = rememberCoroutineScope()
    val colors = LocalTsColors.current
    val ready = url.trim().isNotEmpty() && parent != null

    BackHandler { onClose() }
    // Start at the machine's own home, so the common case needs no picking.
    LaunchedEffect(peer) {
        runCatching { model.workspaceSection(peer, "fs.browse", buildJsonObject {}).jsonObject }
            .onSuccess { answer ->
                if (parent == null) parent = answer["path"]?.jsonPrimitive?.contentOrNull
            }
    }
    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = { Text("Clone a repository") },
                navigationIcon = {
                    TsSecondaryButton(label = "Back", small = true, onClick = onClose)
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = colors.background),
            )
        },
        bottomBar = {
            if (sessionId == null) {
                TsAccentButton(
                    label = if (working) "Starting…" else "Clone",
                    icon = ActionIcon.Download.vector,
                    onClick = {
                        scope.launch {
                            working = true
                            error = null
                            runCatching {
                                val cleanName = name.trim()
                                model.workspaceSection(peer, "workspace.clone", buildJsonObject {
                                    put("url", url.trim())
                                    put("parent", parent!!)
                                    if (cleanName.isNotEmpty()) put("name", cleanName)
                                }).jsonObject
                            }.onSuccess { info ->
                                sessionId = info["id"]?.jsonPrimitive?.contentOrNull
                            }.onFailure { error = SetupFailure.readable(it) }
                            working = false
                        }
                    },
                    modifier = Modifier.fillMaxWidth().padding(horizontal = Space.m, vertical = Space.s),
                    enabled = ready && !working,
                )
            }
        },
    ) { padding ->
        val active = sessionId
        if (active == null) {
            Column(
                Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(Space.m),
                verticalArrangement = Arrangement.spacedBy(Space.m),
            ) {
                Text("Clone onto $hostLabel", style = TsType.title2.copy(fontWeight = FontWeight.SemiBold), color = colors.textPrimary)
                Text(
                    "tokenstat runs git on that machine and registers the folder when it finishes. You watch the whole thing.",
                    style = TsType.body,
                    color = colors.textSecondary,
                )
                if (error != null) Banner(error!!, BannerSeverity.DANGER)
                TsCard {
                    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                        Text("Repository", style = TsType.caption, color = colors.textSecondary)
                        OutlinedTextField(
                            value = url,
                            onValueChange = { url = it },
                            placeholder = { Text("https://github.com/owner/repo.git") },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                        )
                        Text("Where it lands", style = TsType.caption, color = colors.textSecondary)
                        Row(
                            Modifier.fillMaxWidth().clickable { picking = true }.padding(vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                parent ?: "Choose a folder",
                                style = TsType.mono(13),
                                color = if (parent == null) colors.textSecondary else colors.textPrimary,
                                modifier = Modifier.weight(1f).horizontalScroll(rememberScrollState()),
                                maxLines = 1,
                            )
                            Icon(ActionIcon.Next.vector, null, tint = colors.textTertiary)
                        }
                        Text("Folder name", style = TsType.caption, color = colors.textSecondary)
                        OutlinedTextField(
                            value = name,
                            onValueChange = { name = it },
                            placeholder = { Text("taken from the address") },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
                Text(
                    "A private repository asks for its credentials in the terminal, and you can answer there.",
                    style = TsType.caption,
                    color = colors.textSecondary,
                )
            }
        } else {
            CloneRunning(
                model = model,
                peer = peer,
                hostLabel = hostLabel,
                sessionId = active,
                status = status,
                statusAttempt = statusAttempt,
                error = error,
                onStatus = { status = it },
                onError = { error = it },
                onRecheck = { statusAttempt += 1 },
                onBack = { sessionId = null; status = null },
                onOpen = { id -> onCloned(id) },
                modifier = Modifier.padding(padding),
            )
        }
    }
    if (picking) {
        FolderPickerScreen(
            model = model,
            peer = peer,
            hostName = hostLabel,
            title = "Where it lands",
            confirm = "Land it here",
            onClose = { picking = false },
            onChosen = { parent = it; picking = false },
        )
    }
}

private data class CloneStatus(val state: String, val workspaceId: String?, val error: String?)

@Composable
private fun CloneRunning(
    model: AppViewModel,
    peer: String,
    hostLabel: String,
    sessionId: String,
    status: CloneStatus?,
    statusAttempt: Int,
    error: String?,
    onStatus: (CloneStatus?) -> Unit,
    onError: (String?) -> Unit,
    onRecheck: () -> Unit,
    onBack: () -> Unit,
    onOpen: (folderId: String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalTsColors.current
    // The machine registers the folder itself when git exits, so this asks
    // it what happened rather than deciding from what scrolled past. Tied
    // to the view's lifetime, with a timeout instead of sitting on
    // "Cloning…" forever.
    LaunchedEffect(sessionId, statusAttempt) {
        onError(null)
        val deadline = System.currentTimeMillis() + 1_800_000
        while (System.currentTimeMillis() < deadline) {
            val answer = runCatching {
                model.workspaceSection(peer, "workspace.cloneStatus", buildJsonObject {
                    put("sessionId", sessionId)
                }).jsonObject
            }.getOrNull()
            if (answer != null) {
                val next = CloneStatus(
                    state = answer["state"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                    workspaceId = answer["workspaceId"]?.jsonPrimitive?.contentOrNull,
                    error = answer["error"]?.jsonPrimitive?.contentOrNull,
                )
                onStatus(next)
                if (next.state != "running") return@LaunchedEffect
            }
            delay(2_000)
        }
        if (status?.state == "running" || status == null) {
            onError("Status checks stopped after 30 minutes. The clone may still be running. Check the terminal or check its status again.")
        }
    }
    val headline = when {
        error != null -> "Clone status unavailable"
        status?.state == "done" -> "Cloned. The folder is registered on $hostLabel."
        status?.state == "failed" -> status?.error ?: "The clone did not finish."
        else -> "Cloning onto $hostLabel…"
    }
    Column(modifier.fillMaxSize()) {
        Text(headline, style = TsType.subheadline, color = colors.textSecondary, modifier = Modifier.padding(horizontal = Space.m, vertical = Space.s))
        if (error != null) {
            Column(
                Modifier.padding(horizontal = Space.m),
                verticalArrangement = Arrangement.spacedBy(Space.s),
            ) {
                Text(error, style = TsType.caption, color = colors.textSecondary)
                TsSecondaryButton(label = "Check status again", small = true, onClick = onRecheck)
            }
            Spacer(Modifier.height(Space.s))
        }
        androidx.compose.foundation.layout.Box(Modifier.weight(1f)) {
            TerminalScreen(
                model = model,
                peer = peer,
                hostLabel = hostLabel,
                workspaceId = "",
                existingSessionId = sessionId,
                onClose = {},
            )
        }
        if (status?.state == "done" && status?.workspaceId != null) {
            TsAccentButton(
                label = "Open the folder",
                icon = ActionIcon.Next.vector,
                onClick = { onOpen(status.workspaceId) },
                modifier = Modifier.fillMaxWidth().padding(horizontal = Space.m, vertical = Space.s),
            )
        } else if (status?.state == "failed") {
            TsAccentButton(
                label = "Back",
                icon = ActionIcon.Back.vector,
                onClick = onBack,
                modifier = Modifier.fillMaxWidth().padding(horizontal = Space.m, vertical = Space.s),
            )
        }
    }
}

/// A folder on the peer to land a clone in, or to register as-is. Ported
/// from the clone picker's shape in `ClientCloneRepository.swift`: browse,
/// up, make a folder, land here.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FolderPickerScreen(
    model: AppViewModel,
    peer: String,
    hostName: String,
    title: String,
    confirm: String,
    onClose: () -> Unit,
    onChosen: (path: String) -> Unit,
    notice: String? = null,
) {
    val colors = LocalTsColors.current
    val scope = rememberCoroutineScope()
    var path by remember { mutableStateOf<String?>(null) }
    var parentPath by remember { mutableStateOf<String?>(null) }
    var entries by remember { mutableStateOf(listOf<JsonObject>()) }
    var error by remember { mutableStateOf<String?>(null) }
    var naming by remember { mutableStateOf(false) }
    var newFolder by remember { mutableStateOf("") }
    var creating by remember { mutableStateOf(false) }

    fun load(next: String?) {
        scope.launch {
            error = null
            runCatching {
                model.workspaceSection(peer, "fs.browse", buildJsonObject {
                    if (next != null) put("path", next)
                }).jsonObject
            }.onSuccess { answer ->
                path = answer["path"]?.jsonPrimitive?.contentOrNull
                parentPath = answer["parent"]?.jsonPrimitive?.contentOrNull
                entries = (answer["entries"] as? JsonArray)
                    ?.mapNotNull { it as? JsonObject }
                    ?.filter {
                        it["kind"]?.jsonPrimitive?.contentOrNull == "directory" &&
                            it["hidden"]?.jsonPrimitive?.booleanOrNull != true
                    } ?: emptyList()
            }.onFailure { error = SetupFailure.readable(it) }
        }
    }
    LaunchedEffect(peer) { load(null) }
    BackHandler { onClose() }
    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = { Text(title) },
                navigationIcon = {
                    TsSecondaryButton(label = "Back", small = true, onClick = onClose)
                },
                actions = {
                    TsSecondaryButton(
                        label = "New folder",
                        small = true,
                        onClick = { naming = true },
                        enabled = path != null && !creating,
                    )
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = colors.background),
            )
        },
        bottomBar = {
            if (path != null) {
                TsAccentButton(
                    label = confirm,
                    icon = ActionIcon.Approve.vector,
                    onClick = { onChosen(path!!) },
                    modifier = Modifier.fillMaxWidth().padding(horizontal = Space.m, vertical = Space.s),
                )
            }
        },
    ) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding)) {
            if (path != null) {
                item {
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = Space.m, vertical = Space.s),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(Space.s),
                    ) {
                        if (parentPath != null) {
                            TsSecondaryButton(label = "Up", small = true, onClick = { load(parentPath) })
                        }
                        Text(
                            path!!,
                            style = TsType.mono(13),
                            color = colors.textPrimary,
                            maxLines = 1,
                            modifier = Modifier.weight(1f).horizontalScroll(rememberScrollState()),
                        )
                    }
                }
            }
            if (error != null) item { Banner(error!!, BannerSeverity.DANGER, Modifier.padding(horizontal = Space.m)) }
            if (notice != null) item { Banner(notice, BannerSeverity.DANGER, Modifier.padding(horizontal = Space.m)) }
            items(entries, key = { it["path"]?.jsonPrimitive?.contentOrNull ?: it["name"]?.jsonPrimitive?.contentOrNull.orEmpty() }) { entry ->
                Row(
                    Modifier.fillMaxWidth().clickable {
                        entry["path"]?.jsonPrimitive?.contentOrNull?.let { load(it) }
                    }.padding(horizontal = Space.m, vertical = Space.s),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Space.m),
                ) {
                    Icon(Icons.Default.Folder, null, tint = colors.accent)
                    Text(
                        entry["name"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                        style = TsType.body,
                        color = colors.textPrimary,
                    )
                    Spacer(Modifier.weight(1f))
                    Icon(ActionIcon.Next.vector, null, tint = colors.textTertiary)
                }
            }
        }
    }
    if (naming) {
        val here = path
        AlertDialog(
            onDismissRequest = { naming = false; newFolder = "" },
            title = { Text("New folder") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                    Text("It is made on $hostName, inside the folder you are looking at.")
                    OutlinedTextField(
                        value = newFolder,
                        onValueChange = { newFolder = it },
                        placeholder = { Text("Name") },
                        singleLine = true,
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    val clean = newFolder.trim()
                    newFolder = ""
                    if (clean.isEmpty() || here == null) return@TextButton
                    if (clean.contains("/") || clean.contains("\\") || clean == ".." || clean == ".") {
                        error = "A folder name is one name, without a path in it."
                        return@TextButton
                    }
                    naming = false
                    scope.launch {
                        creating = true
                        error = null
                        runCatching {
                            model.workspaceSection(peer, "fs.mkdir", buildJsonObject {
                                put("path", "$here/$clean")
                            }).jsonObject["path"]?.jsonPrimitive?.contentOrNull ?: "$here/$clean"
                        }.onSuccess { made -> load(made) }
                            .onFailure { error = SetupFailure.readable(it) }
                        creating = false
                    }
                }) { Text("Create") }
            },
            dismissButton = {
                TextButton(onClick = { naming = false; newFolder = "" }) { Text("Cancel") }
            },
        )
    }
}

/// Register a folder that is already on the peer. Nothing is copied and
/// nothing is changed.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RegisterFolderScreen(
    model: AppViewModel,
    peer: String,
    hostName: String,
    onClose: () -> Unit,
    onRegistered: (folderId: String) -> Unit,
) {
    var registering by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    FolderPickerScreen(
        model = model,
        peer = peer,
        hostName = hostName,
        title = "A folder on $hostName",
        confirm = if (registering) "Registering…" else "Register this folder",
        notice = error,
        onClose = onClose,
        onChosen = { picked ->
            scope.launch {
                registering = true
                error = null
                runCatching {
                    model.workspaceSection(peer, "workspace.add", buildJsonObject {
                        put("path", picked)
                    }).jsonObject
                }.onSuccess { folder ->
                    onRegistered(folder["id"]?.jsonPrimitive?.contentOrNull.orEmpty())
                }.onFailure { error = SetupFailure.readable(it) }
                registering = false
            }
        },
    )
}
